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
const HOST_COMMAND_REFRESH_INTERVAL: Duration = Duration::from_secs(10);

struct HostConfig {
    revision: u64,
    command: String,
    last_sent: Option<Instant>,
    acknowledged: bool,
}

impl HostConfig {
    fn new(config: &RadarConfig) -> Self {
        // A fresh ID also separates acknowledgments across uploader restarts.
        let revision = rand::random();
        Self {
            revision,
            command: config_command(config, revision),
            last_sent: None,
            acknowledged: false,
        }
    }

    fn should_send(&self, now: Instant) -> bool {
        let interval = if self.acknowledged {
            HOST_COMMAND_REFRESH_INTERVAL
        } else {
            HOST_COMMAND_RESEND_INTERVAL
        };
        self.last_sent
            .is_none_or(|sent| now.duration_since(sent) >= interval)
    }

    fn acknowledge(&mut self, revision: u64) -> bool {
        if self.revision != revision || self.last_sent.is_none() {
            return false;
        }
        if !self.acknowledged {
            log::info!("ESP acknowledged trigger config revision {revision}");
        }
        self.acknowledged = true;
        true
    }

    fn request_refresh(&mut self) {
        self.last_sent = None;
        self.acknowledged = false;
    }
}

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

        mut command_receiver: tokio::sync::mpsc::UnboundedReceiver<Self::Command>,
    ) {
        let (host_command_tx, host_command_rx) = mpsc::channel();
        let worker = tokio::task::spawn_blocking(move || self.read_loop(host_command_rx));
        supervise_reader(&mut command_receiver, host_command_tx, worker).await;
    }
}

async fn supervise_reader(
    commands: &mut tokio::sync::mpsc::UnboundedReceiver<RadarReaderCommand>,
    host_commands: mpsc::Sender<RadarConfig>,
    mut worker: tokio::task::JoinHandle<()>,
) {
    let result = loop {
        tokio::select! {
            result = &mut worker => break result,
            command = commands.recv() => {
                let Some(RadarReaderCommand::UpdateConfig(config)) = command else {
                    // Blocking tasks cannot be aborted. Closing their input asks
                    // the serial loop to stop after its bounded read timeout.
                    drop(host_commands);
                    break worker.await;
                };
                if host_commands.send(config).is_err() {
                    break worker.await;
                }
            }
        }
    };
    match result {
        Ok(()) => log::error!("Radar reader stopped"),
        Err(error) => log::error!("Radar reader thread failed: {error}"),
    }
}

impl RadarReader {
    fn read_loop(self, host_command_rx: mpsc::Receiver<RadarConfig>) {
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
        log::info!("Listening for logs on {}...", self.serial_port);
        log::info!(
            "Sending ESP trigger config on {}...",
            self.config_serial_port
        );

        loop {
            loop {
                match host_command_rx.try_recv() {
                    Ok(command) => {
                        latest_host_command = Some(HostConfig::new(&command));
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return,
                }
            }

            match config_port.read(&mut config_buffer) {
                Ok(num_bytes) => {
                    process_config_response_bytes(
                        &config_buffer[..num_bytes],
                        &mut config_line,
                        &mut latest_host_command,
                    );
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

            if let Some(config) = latest_host_command.as_mut() {
                if config.should_send(Instant::now()) {
                    if let Err(error) = config_port.write_all(config.command.as_bytes()) {
                        log::error!("Failed to write ESP config command: {error}");
                    } else if let Err(error) = config_port.flush() {
                        log::error!("Failed to flush ESP config command: {error}");
                    } else {
                        log::info!(
                            "Sent ESP trigger config on {}: {}",
                            self.config_serial_port,
                            config.command.trim_end()
                        );
                        config.last_sent = Some(Instant::now());
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

fn process_config_response_bytes(
    bytes: &[u8],
    line_buf: &mut Vec<u8>,
    latest: &mut Option<HostConfig>,
) {
    for byte in bytes {
        match *byte {
            b'\n' | b'\r' => {
                if line_buf.is_empty() {
                    continue;
                }

                let line = String::from_utf8_lossy(line_buf).into_owned();
                match line.as_str() {
                    "CONFIG_READY" => {
                        if let Some(config) = latest.as_mut() {
                            config.request_refresh();
                        }
                    }
                    line if line.starts_with("CONFIG_OK ") => {
                        if let (Some(config), Ok(revision)) =
                            (latest.as_mut(), line[10..].parse::<u64>())
                        {
                            config.acknowledge(revision);
                        }
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
}

fn config_command(config: &RadarConfig, revision: u64) -> String {
    format!(
        "CONFIG_V2 {} {} {} {} {} {} {}\n",
        revision,
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

    #[tokio::test]
    async fn supervision_detects_worker_exit_without_waiting_for_commands() {
        for panic in [false, true] {
            let (_commands_tx, mut commands_rx) = tokio::sync::mpsc::unbounded_channel();
            let (host_tx, _host_rx) = mpsc::channel();
            let worker = tokio::task::spawn_blocking(move || {
                assert!(!panic, "simulated serial worker panic");
            });
            tokio::time::timeout(
                Duration::from_secs(1),
                supervise_reader(&mut commands_rx, host_tx, worker),
            )
            .await
            .expect("a stopped reader must wake the process even with a live config channel");
        }
    }

    #[tokio::test]
    async fn closing_commands_stops_the_blocking_worker() {
        let (commands_tx, mut commands_rx) = tokio::sync::mpsc::unbounded_channel();
        let (host_tx, host_rx) = mpsc::channel();
        let worker = tokio::task::spawn_blocking(move || {
            assert!(host_rx.recv().is_err());
        });
        drop(commands_tx);
        tokio::time::timeout(
            Duration::from_secs(1),
            supervise_reader(&mut commands_rx, host_tx, worker),
        )
        .await
        .expect("the serial worker must observe command channel shutdown");
    }

    fn config() -> RadarConfig {
        RadarConfig {
            authorized_speed: 42,
            min_dist: 1234.5,
            max_dist: 9876.5,
            trigger_cooldown: 1500,
            aperture_angle: 64,
            capture_paused: true,
        }
    }

    #[test]
    fn formats_config_command_for_esp_trigger() {
        assert_eq!(
            config_command(&config(), 7),
            "CONFIG_V2 7 42 1235 9877 1500 64 1\n"
        );
    }

    #[test]
    fn only_the_current_sent_revision_can_be_acknowledged() {
        let now = Instant::now();
        let mut a = HostConfig::new(&config());
        a.last_sent = Some(now);
        let ack_a = format!("CONFIG_OK {}\n", a.revision);
        let b = HostConfig::new(&config());
        let ack_b = format!("CONFIG_OK {}\n", b.revision);
        let mut latest = Some(b);
        let mut line = vec![];

        // B arrives while A's acknowledgment is still in the serial buffer.
        process_config_response_bytes(ack_a.as_bytes(), &mut line, &mut latest);
        assert!(latest.as_ref().unwrap().should_send(now));
        assert!(!latest.as_ref().unwrap().acknowledged);
        // Even a matching response cannot acknowledge a command not yet sent.
        process_config_response_bytes(ack_b.as_bytes(), &mut line, &mut latest);
        assert!(!latest.as_ref().unwrap().acknowledged);

        latest.as_mut().unwrap().last_sent = Some(now);
        // Generic ACKs and old firmware logs are not protocol acknowledgments.
        process_config_response_bytes(
            b"CONFIG_OK\nTrigger config updated: paused=false\nCONFIG_ERR\n",
            &mut line,
            &mut latest,
        );
        assert!(!latest.as_ref().unwrap().acknowledged);
        process_config_response_bytes(&ack_b.as_bytes()[..5], &mut line, &mut latest);
        assert!(!latest.as_ref().unwrap().acknowledged);
        process_config_response_bytes(&ack_b.as_bytes()[5..], &mut line, &mut latest);
        assert!(latest.as_ref().unwrap().acknowledged);
        assert!(!latest.as_ref().unwrap().should_send(now));
        assert!(line.is_empty());
    }

    #[test]
    fn current_config_is_retried_and_restored_after_esp_restart() {
        let now = Instant::now();
        let mut config = HostConfig::new(&config());
        let command = config.command.clone();
        config.last_sent = Some(now);
        assert!(!config.should_send(now));
        assert!(config.should_send(now + HOST_COMMAND_RESEND_INTERVAL));
        assert!(config.acknowledge(config.revision));
        assert!(!config.should_send(now + HOST_COMMAND_RESEND_INTERVAL));
        assert!(config.should_send(now + HOST_COMMAND_REFRESH_INTERVAL));

        let mut latest = Some(config);
        process_config_response_bytes(b"CONFIG_READY\n", &mut vec![], &mut latest);
        let config = latest.unwrap();
        assert!(config.should_send(now));
        assert!(!config.acknowledged);
        assert_eq!(config.command, command);
    }
}
