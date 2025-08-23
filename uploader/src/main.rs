mod actor;

use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use clap::Parser;
use defmt_decoder::{DecodeError, Table};
use env_logger::Env;
use eyre::{Context, Result, eyre};
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
    elf_path: Utf8PathBuf,

    #[arg(short, long)]
    photos_dir: Utf8PathBuf,
}

impl Args {
    fn check(&self) -> Result<()> {
        if !(self.photos_dir.exists() && self.photos_dir.is_dir()) {
            return Err(eyre!(
                "Photos directory does not exist: {}",
                self.photos_dir
            ));
        }
        Ok(())
    }
}

fn main() -> Result<()> {
    env_logger::init_from_env(Env::default().default_filter_or("info"));

    let args = Args::parse();
    args.check()?;
    let elf_bytes = fs::read(&args.elf_path)?;
    let table = Table::parse(&elf_bytes)
        .map_err(|e| eyre!("Failed to parse .defmt data: {e}"))?
        .ok_or_else(|| eyre!(".defmt data not found"))?;
    let mut stream_decoder = table.new_stream_decoder();

    log::info!("Starting uploader...");
    log::info!("Attempting to open serial port: {}", args.serial_port);

    let mut port = serialport::new(&args.serial_port, 115_200)
        .data_bits(serialport::DataBits::Eight)
        .parity(serialport::Parity::None)
        .stop_bits(serialport::StopBits::One)
        .flow_control(serialport::FlowControl::None)
        .timeout(Duration::from_millis(50))
        .open()?;

    port.clear(serialport::ClearBuffer::All)?;

    let mut buffer = [0; 4096];
    log::info!("Listening for logs on {}...", args.serial_port);

    let mut offset = 0;
    let mut infraction_recorder = InfractionRecorder::new(25, args.photos_dir);
    loop {
        match port.read(&mut buffer) {
            Ok(num_bytes) => {
                offset += num_bytes;
                stream_decoder.received(&buffer[..offset]);
                loop {
                    match stream_decoder.decode() {
                        Ok(frame) => {
                            let log_message = frame.display_message().to_string();
                            if let Err(err) = infraction_recorder.update(log_message) {
                                log::error!("Failed to update infraction recorder: {err}");
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
    Ok(())
}

#[derive(Default)]
struct InfractionRecorder {
    authorized_speed: i16,
    last_infraction: Option<Infraction>,
    photos_dir: Utf8PathBuf,
}

impl InfractionRecorder {
    const MAX_SPEED_PREFIX: &str = "EVENTS: MAX_SPEED: ";

    fn new(authorized_speed: i16, photos_dir: Utf8PathBuf) -> Self {
        Self {
            authorized_speed,
            photos_dir,
            ..Default::default()
        }
    }

    fn update(&mut self, message: String) -> Result<()> {
        if let Some(infraction) = &self.last_infraction
            && (Utc::now().signed_duration_since(infraction.datetime_taken) < TimeDelta::seconds(1)
                || !message.starts_with(Self::MAX_SPEED_PREFIX))
        {
            return Ok(());
        }
        let max_speed = message
            .strip_prefix(Self::MAX_SPEED_PREFIX)
            .unwrap()
            .parse::<i16>()
            .wrap_err("Failed to parse max speed")?;
        if max_speed > self.authorized_speed {
            let infraction = Infraction {
                recorded_speed: max_speed,
                authorized_speed: self.authorized_speed,
                location: "Lorgues".to_string(),
                datetime_taken: Utc::now(),
            };
            log::info!("Infraction: {infraction:#?}");
            self.take_picture(&infraction)?;
            self.last_infraction = Some(infraction);
        }
        Ok(())
    }

    fn take_picture(&self, infraction: &Infraction) -> Result<()> {
        let output = duct::cmd(
            "gphoto2",
            &[
                "--capture-image-and-download",
                "--force-overwrite",
                "--filename",
                infraction.photo_path(&self.photos_dir).as_str(),
            ],
        )
        .stderr_to_stdout()
        .stdout_capture()
        .unchecked()
        .run()?;
        if !output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            return Err(eyre::eyre!(
                "gphoto2 command failed with status {}:\n{}",
                output.status,
                stdout
            ));
        }

        Ok(())
    }
}

#[derive(Debug)]
struct Infraction {
    recorded_speed: i16,
    authorized_speed: i16,
    location: String,
    datetime_taken: DateTime<Utc>,
}

impl Infraction {
    fn photo_path(&self, photos_dir: &Utf8Path) -> Utf8PathBuf {
        photos_dir.join(format!("{}.jpg", self.datetime_taken.to_rfc3339()))
    }
}
