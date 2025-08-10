use clap::Parser;
use defmt_decoder::{DecodeError, Table};
use log::{error, info};
use std::fs;
use std::io::Read;
use std::time::Duration;

const EVENT_PREFIX: &str = "EVENTS: ";
const MAX_SPEED_PREFIX: &str = "MAX_SPEED: ";

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
    loop {
        match port.read(&mut buffer) {
            Ok(n) => {
                offset += n;
                stream_decoder.received(&buffer[..offset]);
                loop {
                    match stream_decoder.decode() {
                        Ok(frame) => {
                            let log_message = frame.display(true).to_string();
                            handle_radar_message(log_message);
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

fn handle_radar_message(message: String) {
    if message.starts_with(EVENT_PREFIX) {
        handle_event(message.strip_prefix(EVENT_PREFIX).unwrap());
    } else {
        println!("Received log: {message}");
    }
}

fn handle_event(event: &str) {
    if event.starts_with(MAX_SPEED_PREFIX) {
        let max_speed = event.strip_prefix(MAX_SPEED_PREFIX).unwrap();
        let max_speed = max_speed.parse::<i16>();
        if max_speed > 50 {
            let infraction = Infraction {
                recorded_speed: max_speed,
                authorized_speed: AUTHORIZED_SPEED,
                location: "Lorgues".to_string(),
                datetime_taken: Utc::now(),
            };
        }
    }
}
