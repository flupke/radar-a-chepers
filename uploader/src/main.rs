use camino::Utf8PathBuf;
use clap::Parser;
use env_logger::Env;
use eyre::{Result, eyre};
use tokio::sync::broadcast;

use uploader::{
    actor::Actor,
    config_channel,
    fake_radar_reader::FakeRadarReader,
    infraction_recorder::{InfractionRecorder, InfractionRecorderCommand},
    infraction_uploader::InfractionUploader,
    radar_reader::RadarReader,
};

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short('e'), long)]
    api_endpoint: String,

    #[arg(short, long)]
    api_key: String,

    #[arg(short, long)]
    serial_port: Option<String>,

    #[arg(long)]
    elf_path: Option<Utf8PathBuf>,

    #[arg(short, long)]
    infractions_dir: Utf8PathBuf,

    #[arg(long)]
    test_mode: bool,
}

impl Args {
    fn check(&self) -> Result<()> {
        if !(self.infractions_dir.exists() && self.infractions_dir.is_dir()) {
            return Err(eyre!(
                "Infractions directory does not exist: {}",
                self.infractions_dir
            ));
        }
        if !self.test_mode {
            if self.elf_path.is_none() {
                return Err(eyre!("--elf-path is required when not in test mode"));
            }
            if self.serial_port.is_none() {
                return Err(eyre!("--serial-port is required when not in test mode"));
            }
        }
        Ok(())
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    env_logger::init_from_env(Env::default().default_filter_or("info"));

    let args = Args::parse();
    args.check()?;

    let (target_data_tx, target_data_rx) = broadcast::channel(64);

    // Bridge channel: config_channel (Send) -> LocalSet actor (!Send)
    let (config_tx, mut config_rx) = tokio::sync::mpsc::unbounded_channel();

    let api_endpoint = args.api_endpoint.clone();
    let api_key = args.api_key.clone();
    let test_mode = args.test_mode;

    // Spawn config channel on a regular tokio task (needs Send)
    tokio::spawn(config_channel::run(
        api_endpoint,
        api_key,
        config_tx,
        target_data_rx,
    ));

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let infraction_uploader = InfractionUploader::new(
                args.infractions_dir.clone(),
                args.api_endpoint,
                args.api_key,
            );
            let infraction_recorder = InfractionRecorder::new(
                25,
                args.infractions_dir,
                &infraction_uploader,
                target_data_tx,
                test_mode,
            );
            let recorder_port = infraction_recorder.port().clone();

            // Bridge: forward config updates from the Send channel to the local actor
            tokio::task::spawn_local(async move {
                while let Some(config) = config_rx.recv().await {
                    let _ = recorder_port.send(InfractionRecorderCommand::UpdateConfig(config));
                }
            });

            if test_mode {
                let reader = FakeRadarReader::new(infraction_recorder).start();
                reader.join().await;
            } else {
                let reader = RadarReader::new(
                    args.elf_path.unwrap(),
                    args.serial_port.unwrap(),
                    infraction_recorder,
                )
                .start();
                reader.join().await;
            }
        })
        .await;

    Ok(())
}
