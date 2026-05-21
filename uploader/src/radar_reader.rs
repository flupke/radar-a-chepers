use std::{
    io::{Read, Write},
    sync::mpsc,
    time::{Duration, Instant},
};

use camino::Utf8PathBuf;
use defmt_decoder::{DecodeError, Table};

use crate::{
    actor::Actor,
    infraction_recorder::{RadarConfig, RadarInput},
};

const HOST_COMMAND_RESEND_INTERVAL: Duration = Duration::from_secs(1);

pub enum RadarReaderCommand {
    UpdateConfig(RadarConfig),
}

pub struct RadarReader {
    elf_path: Utf8PathBuf,
    serial_port: String,
    config_serial_port: String,
    radar_input: RadarInput,
}

impl RadarReader {
    pub fn new(
        elf_path: Utf8PathBuf,
        serial_port: String,
        config_serial_port: String,
        radar_input: RadarInput,
    ) -> Self {
        Self {
            elf_path,
            serial_port,
            config_serial_port,
            radar_input,
        }
    }
}

impl Actor for RadarReader {
    type Command = RadarReaderCommand;

    async fn event_loop(
        self,
        _port: crate::actor::ActorPort<Self::Command>,
        mut command_receiver: tokio::sync::mpsc::UnboundedReceiver<Self::Command>,
    ) {
        let (host_command_tx, host_command_rx) = mpsc::channel();
        let join_result = tokio::task::spawn_blocking(move || self.read_loop(host_command_rx));

        while let Some(command) = command_receiver.recv().await {
            match command {
                RadarReaderCommand::UpdateConfig(config) => {
                    let _ = host_command_tx.send(config_command(&config));
                }
            }
        }

        let join_result = join_result.await;
        if let Err(error) = join_result {
            log::error!("Radar reader thread failed: {error}");
        }
    }
}

impl RadarReader {
    fn read_loop(self, host_command_rx: mpsc::Receiver<String>) {
        let elf_bytes = std::fs::read(&self.elf_path).expect("Failed to read ELF file");
        let table = Table::parse(&elf_bytes)
            .expect("Failed to parse .defmt data: {e}")
            .expect("No .defmt data found");
        let mut stream_decoder = table.new_stream_decoder();

        let mut log_port = tokio_serial::new(&self.serial_port, 115_200)
            .data_bits(tokio_serial::DataBits::Eight)
            .parity(tokio_serial::Parity::None)
            .stop_bits(tokio_serial::StopBits::One)
            .flow_control(tokio_serial::FlowControl::None)
            .timeout(Duration::from_millis(50))
            .open()
            .unwrap_or_else(|error| {
                panic!(
                    "Failed to open ESP log serial port {}: {error}",
                    self.serial_port
                )
            });

        let mut config_port = tokio_serial::new(&self.config_serial_port, 115_200)
            .data_bits(tokio_serial::DataBits::Eight)
            .parity(tokio_serial::Parity::None)
            .stop_bits(tokio_serial::StopBits::One)
            .flow_control(tokio_serial::FlowControl::None)
            .timeout(Duration::from_millis(5))
            .open()
            .unwrap_or_else(|error| {
                panic!(
                    "Failed to open ESP config serial port {}: {error}",
                    self.config_serial_port
                )
            });

        let _ = log_port.clear(tokio_serial::ClearBuffer::All);
        let _ = config_port.clear(tokio_serial::ClearBuffer::All);
        if let Err(error) = log_port.write_data_terminal_ready(true) {
            log::warn!("Failed to set ESP serial DTR: {error}");
        }
        if let Err(error) = log_port.write_request_to_send(true) {
            log::warn!("Failed to set ESP serial RTS: {error}");
        }

        let mut buffer = [0; 4096];
        let mut config_buffer = [0; 256];
        let mut config_line = Vec::with_capacity(128);
        let mut latest_host_command = None;
        let mut last_host_command_sent_at: Option<Instant> = None;
        log::info!("Listening for logs on {}...", self.serial_port);
        log::info!(
            "Sending ESP trigger config on {}...",
            self.config_serial_port
        );

        loop {
            while let Ok(command) = host_command_rx.try_recv() {
                latest_host_command = Some(command);
                last_host_command_sent_at = None;
            }

            match config_port.read(&mut config_buffer) {
                Ok(num_bytes) => {
                    if process_config_response_bytes(&config_buffer[..num_bytes], &mut config_line)
                    {
                        latest_host_command = None;
                        last_host_command_sent_at = None;
                    }
                }
                Err(ref error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) => {}
                Err(error) => {
                    log::error!("Failed to read from ESP config serial port: {error}");
                    break;
                }
            }

            if let Some(command) = latest_host_command.as_deref() {
                let should_send = match last_host_command_sent_at {
                    Some(sent_at) => sent_at.elapsed() >= HOST_COMMAND_RESEND_INTERVAL,
                    None => true,
                };

                if should_send {
                    if let Err(error) = config_port.write_all(command.as_bytes()) {
                        log::error!("Failed to write ESP config command: {error}");
                    } else if let Err(error) = config_port.flush() {
                        log::error!("Failed to flush ESP config command: {error}");
                    } else {
                        log::info!(
                            "Sent ESP trigger config on {}: {}",
                            self.config_serial_port,
                            command.trim_end()
                        );
                        last_host_command_sent_at = Some(Instant::now());
                    }
                }
            }

            match log_port.read(&mut buffer) {
                Ok(num_bytes) => {
                    if num_bytes == 0 {
                        std::thread::yield_now();
                        continue;
                    }

                    stream_decoder.received(&buffer[..num_bytes]);
                    loop {
                        match stream_decoder.decode() {
                            Ok(frame) => {
                                let log_message = frame.display_message().to_string();
                                if log_message.starts_with("Trigger config updated:") {
                                    latest_host_command = None;
                                    last_host_command_sent_at = None;
                                }
                                self.radar_input.process_log_message(log_message);
                            }
                            Err(DecodeError::UnexpectedEof) => {
                                // Need more data
                                break;
                            }
                            Err(DecodeError::Malformed) => match table.encoding().can_recover() {
                                // if recovery is impossible, abort
                                false => {
                                    log::error!("Malformed frame skipped");
                                    break;
                                }
                                // if recovery is possible, skip the current frame and continue with new data
                                true => {
                                    continue;
                                }
                            },
                        }
                    }
                }
                Err(ref error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) =>
                {
                    std::thread::yield_now();
                }
                Err(error) => {
                    log::error!("Failed to read from serial port: {error}");
                    break;
                }
            }
        }
    }
}

fn process_config_response_bytes(bytes: &[u8], line_buf: &mut Vec<u8>) -> bool {
    let mut acknowledged = false;

    for byte in bytes {
        match *byte {
            b'\n' | b'\r' => {
                if line_buf.is_empty() {
                    continue;
                }

                let line = String::from_utf8_lossy(line_buf).into_owned();
                match line.as_str() {
                    "CONFIG_OK" => {
                        log::info!("ESP acknowledged trigger config");
                        acknowledged = true;
                    }
                    "CONFIG_ERR" => {
                        log::warn!("ESP rejected trigger config");
                    }
                    _ => {
                        log::info!("ESP config UART: {line}");
                    }
                }
                line_buf.clear();
            }
            byte if line_buf.len() < 256 => line_buf.push(byte),
            _ => {
                log::warn!("ESP config UART line too long; discarding");
                line_buf.clear();
            }
        }
    }

    acknowledged
}

fn config_command(config: &RadarConfig) -> String {
    format!(
        "CONFIG {} {} {} {} {} {}\n",
        config.authorized_speed,
        config.min_dist.round() as i64,
        config.max_dist.round() as i64,
        config.trigger_cooldown,
        config.aperture_angle,
        if config.capture_paused { 1 } else { 0 }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_config_command_for_esp_trigger() {
        let config = RadarConfig {
            authorized_speed: 42,
            min_dist: 1234.5,
            max_dist: 9876.5,
            trigger_cooldown: 1500,
            aperture_angle: 64,
            capture_paused: true,
        };

        assert_eq!(config_command(&config), "CONFIG 42 1235 9877 1500 64 1\n");
    }

    #[test]
    fn config_ok_response_acknowledges_config() {
        let mut line_buf = Vec::new();

        assert!(!process_config_response_bytes(b"CONFIG", &mut line_buf));
        assert!(process_config_response_bytes(b"_OK\n", &mut line_buf));
        assert!(line_buf.is_empty());
    }

    #[test]
    fn config_error_response_does_not_acknowledge_config() {
        let mut line_buf = Vec::new();

        assert!(!process_config_response_bytes(
            b"CONFIG_ERR\n",
            &mut line_buf
        ));
        assert!(line_buf.is_empty());
    }
}
