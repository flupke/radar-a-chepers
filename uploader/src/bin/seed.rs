use camino::Utf8PathBuf;
use clap::Parser;
use std::path::Path;
use uploader::infraction_recorder::Infraction;
use uploader::infraction_uploader::{InfractionUploader, InfractionUploaderCommand};

#[derive(Parser)]
#[command(about = "Seed the radar web app with test infractions")]
struct Args {
    #[arg(short('e'), long, default_value = "http://localhost:4000")]
    api_endpoint: String,

    #[arg(short, long, default_value = "radar-dev-key")]
    api_key: String,
}

const LOCATIONS: &[&str] = &[
    "Interstate 5 Mile 100",
    "Highway 101 Mile 42",
    "Downtown 3rd Ave & Pine",
    "SR-520 Eastbound",
    "I-80 West Exit 12",
];

#[tokio::main(flavor = "current_thread")]
async fn main() {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let args = Args::parse();
    let images_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../web/priv/static/images");
    let tmp_dir = tempfile::tempdir().expect("Failed to create temp dir");
    let infractions_dir = Utf8PathBuf::from_path_buf(tmp_dir.path().to_path_buf())
        .expect("Temp dir path is not UTF-8");
    let now = chrono::Utc::now();

    println!("==> Writing seed infractions to {infractions_dir}...");

    for i in 1..=5i16 {
        let speed = 60 + i * 5;
        let location = LOCATIONS[(i - 1) as usize];
        let infraction = Infraction {
            recorded_speed: speed,
            authorized_speed: 55,
            location: location.to_string(),
            datetime_taken: now - chrono::Duration::hours(i as i64),
        };

        let src = images_dir.join(format!("seed_{i}.jpg"));
        std::fs::copy(&src, infraction.photo_path(&infractions_dir))
            .unwrap_or_else(|e| panic!("Failed to copy {}: {e}", src.display()));
        infraction
            .save_infraction_json(&infractions_dir)
            .unwrap_or_else(|e| panic!("Failed to write JSON: {e}"));

        println!("    seed_{i}.jpg ({speed} MPH at {location})");
    }

    println!("==> Uploading via InfractionUploader...");

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let uploader = InfractionUploader::new(
                infractions_dir,
                args.api_endpoint,
                args.api_key,
            );
            uploader
                .port
                .send(InfractionUploaderCommand::NotifyInfraction)
                .expect("Failed to send to uploader");
            uploader
                .port
                .send(InfractionUploaderCommand::Shutdown)
                .expect("Failed to send shutdown");
            uploader.port.join().await;
        })
        .await;

    println!("==> Done!");
}
