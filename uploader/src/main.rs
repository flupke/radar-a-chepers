use chrono::{DateTime, TimeDelta, Utc};
use clap::Parser;
use defmt_decoder::{DecodeError, Table};
use log::{error, info};
use std::fs;
use std::io::Read;
use std::time::Duration;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short('e'), long)]
    api_endpoint: String,

    #[arg(short, long)]
    api_key: String,

    #[arg(short, long)]
    serial_port: String,

    #[arg(long)]
    elf_path: String,
}

fn main() -> anyhow::Result<()> {
    env_logger::init();

    let args = Args::parse();
    let elf_path = args.elf_path;
    let port_name = args.serial_port;

    let elf_bytes = fs::read(&elf_path)?;
    let table =
        Table::parse(&elf_bytes)?.ok_or_else(|| anyhow::anyhow!(".defmt data not found"))?;
    let mut stream_decoder = table.new_stream_decoder();

    info!("Starting uploader...");
    info!("Attempting to open serial port: {port_name}");

    let mut port = serialport::new(&port_name, 115_200)
        .data_bits(serialport::DataBits::Eight)
        .parity(serialport::Parity::None)
        .stop_bits(serialport::StopBits::One)
        .flow_control(serialport::FlowControl::None)
        .timeout(Duration::from_millis(50))
        .open()?;

    port.clear(serialport::ClearBuffer::All)?;

    let mut buffer = [0; 4096];
    info!("Listening for logs on {port_name}...");

    let mut offset = 0;
    let mut infraction_recorder = InfractionRecorder::new(25);
    loop {
        match port.read(&mut buffer) {
            Ok(n) => {
                offset += n;
                stream_decoder.received(&buffer[..offset]);
                loop {
                    match stream_decoder.decode() {
                        Ok(frame) => {
                            let log_message = frame.display_message().to_string();
                            infraction_recorder.update(log_message);
                            offset = 0;
                        }
                        Err(DecodeError::UnexpectedEof) => {
                            // Need more data
                            break;
                        }
                        Err(DecodeError::Malformed) => match table.encoding().can_recover() {
                            // if recovery is impossible, abort
                            false => {
                                error!("Malformed frame skipped");
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
            Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => (),
            Err(e) => {
                error!("Failed to read from serial port: {e}");
                break;
            }
        }
    }
    Ok(())
}

#[derive(Default)]
struct InfractionRecorder {
    authorized_speed: i16,
    last_infraction: Option<Infraction>,
}

impl InfractionRecorder {
    const MAX_SPEED_PREFIX: &str = "EVENTS: MAX_SPEED: ";

    fn new(authorized_speed: i16) -> Self {
        Self {
            authorized_speed,
            ..Default::default()
        }
    }

    fn update(&mut self, message: String) {
        if let Some(infraction) = &self.last_infraction {
            if Utc::now().signed_duration_since(infraction.datetime_taken) < TimeDelta::seconds(1) {
                return;
            }
        }

        if !message.starts_with(Self::MAX_SPEED_PREFIX) {
            return;
        }
        let max_speed = message.strip_prefix(Self::MAX_SPEED_PREFIX).unwrap();
        let Ok(max_speed) = max_speed.parse::<i16>() else {
            log::error!("Failed to parse max speed: {max_speed}");
            return;
        };
        if max_speed > self.authorized_speed {
            let infraction = Infraction {
                recorded_speed: max_speed,
                authorized_speed: self.authorized_speed,
                location: "Lorgues".to_string(),
                datetime_taken: Utc::now(),
            };
            println!("Infraction: {:#?}", infraction);
            self.last_infraction = Some(infraction);
        }
    }

    fn record_infraction(&mut self, infraction: Infraction) {
        self.last_infraction = Some(infraction);
    }
}

#[derive(Debug)]
struct Infraction {
    recorded_speed: i16,
    authorized_speed: i16,
    location: String,
    datetime_taken: DateTime<Utc>,
}
