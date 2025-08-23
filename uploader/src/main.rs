mod actor;
mod infraction_recorder;
mod infraction_uploader;
mod radar_reader;

use camino::Utf8PathBuf;
use clap::Parser;
use env_logger::Env;
use eyre::{Result, eyre};

use crate::{actor::Actor, infraction_recorder::InfractionRecorder, infraction_uploader::InfractionUploader, radar_reader::RadarReader};

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
    infractions_dir: Utf8PathBuf,
}

impl Args {
    fn check(&self) -> Result<()> {
        if !(self.infractions_dir.exists() && self.infractions_dir.is_dir()) {
            return Err(eyre!(
                "Infractions directory does not exist: {}",
                self.infractions_dir
            ));
        }
        Ok(())
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    env_logger::init_from_env(Env::default().default_filter_or("info"));

    let args = Args::parse();
    args.check()?;

    let infraction_uploader = InfractionUploader::new(args.infractions_dir).start();
    let infraction_recorder = InfractionRecorder::new(25, args.infractions_dir, infraction_uploader)
    let radar_reader =
        RadarReader::new(args.elf_path, args.serial_port, infraction_recorder).start();
    radar_reader.join().await;

    Ok(())
}
