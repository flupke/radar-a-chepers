use std::time::Duration;

use camino::Utf8PathBuf;
use defmt_decoder::{DecodeError, Table};
use tokio::time::sleep;

use crate::{actor::Actor, infraction_recorder::InfractionRecorder};

pub(crate) struct RadarReader {
    elf_path: Utf8PathBuf,
    serial_port: String,
    infraction_recorder: InfractionRecorder,
}

impl RadarReader {
    pub(crate) fn new(
        elf_path: Utf8PathBuf,
        serial_port: String,
        infraction_recorder: InfractionRecorder,
    ) -> Self {
        Self {
            elf_path,
            serial_port,
            infraction_recorder,
        }
    }
}

impl Actor for RadarReader {
    type Command = ();

    async fn event_loop(
        self,
        _port: crate::actor::ActorPort<Self::Command>,
        _command_receiver: tokio::sync::mpsc::UnboundedReceiver<Self::Command>,
    ) {
        let elf_bytes = std::fs::read(&self.elf_path).expect("Failed to read ELF file");
        let table = Table::parse(&elf_bytes)
            .expect("Failed to parse .defmt data: {e}")
            .expect("No .defmt data found");
        let mut stream_decoder = table.new_stream_decoder();

        let mut port = tokio_serial::new(&self.serial_port, 115_200)
            .data_bits(tokio_serial::DataBits::Eight)
            .parity(tokio_serial::Parity::None)
            .stop_bits(tokio_serial::StopBits::One)
            .flow_control(tokio_serial::FlowControl::None)
            .timeout(Duration::from_millis(50))
            .open()
            .unwrap();

        let _ = port.clear(tokio_serial::ClearBuffer::All);

        let mut buffer = [0; 4096];
        log::info!("Listening for logs on {}...", self.serial_port);

        let mut offset = 0;
        loop {
            match port.read(&mut buffer) {
                Ok(num_bytes) => {
                    offset += num_bytes;
                    stream_decoder.received(&buffer[..offset]);
                    loop {
                        match stream_decoder.decode() {
                            Ok(frame) => {
                                let log_message = frame.display_message().to_string();
                                self.infraction_recorder
                                    .process_log_message(log_message)
                                    .await;
                                // Clear buffer after taking a photo so we don't re-trigger a photo
                                // immediately
                                sleep(Duration::from_millis(100)).await;
                                if let Err(err) = port.clear(tokio_serial::ClearBuffer::Input) {
                                    log::error!("Failed to clear serial input buffer: {err}");
                                }
                                offset = 0;
                            }
                            Err(DecodeError::UnexpectedEof) => {
                                // Need more data
                                break;
                            }
                            Err(DecodeError::Malformed) => match table.encoding().can_recover() {
                                // if recovery is impossible, abort
                                false => {
                                    log::error!("Malformed frame skipped");
                                    offset = 0;
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
                Err(ref error) if error.kind() == std::io::ErrorKind::TimedOut => (),
                Err(error) => {
                    log::error!("Failed to read from serial port: {error}");
                    break;
                }
            }
        }
    }
}
