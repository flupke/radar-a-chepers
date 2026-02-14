use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use eyre::{Context, Result};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::{
    actor::{Actor, ActorPort},
    infraction_uploader::{InfractionUploader, InfractionUploaderCommand},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RadarConfig {
    pub authorized_speed: i16,
    pub min_dist: f64,
    pub max_dist: f64,
    pub trigger_cooldown: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TargetData {
    pub speed: i16,
    pub x: i16,
    pub y: i16,
    pub distance: f64,
    pub triggered: bool,
}

pub struct InfractionRecorder {
    port: ActorPort<InfractionRecorderCommand>,
}

impl InfractionRecorder {
    pub fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        infraction_uploader: &InfractionUploader,
        target_data_tx: broadcast::Sender<TargetData>,
        test_mode: bool,
    ) -> Self {
        Self {
            port: InfractionRecorderInner::new(
                authorized_speed,
                photos_dir,
                infraction_uploader.port.clone(),
                target_data_tx,
                test_mode,
            )
            .start(),
        }
    }

    pub fn port(&self) -> &ActorPort<InfractionRecorderCommand> {
        &self.port
    }

    pub(crate) async fn process_log_message(&self, message: String) {
        let (sender, receiver) = oneshot::channel();
        self.port
            .send(InfractionRecorderCommand::ProcessLogMessage(
                sender, message,
            ))
            .expect("Failed to send message to infraction recorder");
        receiver.await.unwrap();
    }
}

pub enum InfractionRecorderCommand {
    ProcessLogMessage(oneshot::Sender<()>, String),
    UpdateConfig(RadarConfig),
}

struct InfractionRecorderInner {
    authorized_speed: i16,
    min_dist: f64,
    max_dist: f64,
    trigger_cooldown_ms: i64,
    last_infraction: Option<Infraction>,
    photos_dir: Utf8PathBuf,
    uploader_port: ActorPort<InfractionUploaderCommand>,
    target_data_tx: broadcast::Sender<TargetData>,
    test_mode: bool,
}

impl Actor for InfractionRecorderInner {
    type Command = InfractionRecorderCommand;

    async fn event_loop(
        mut self,
        _port: ActorPort<Self::Command>,
        mut command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) {
        while let Some(command) = command_receiver.recv().await {
            match command {
                InfractionRecorderCommand::ProcessLogMessage(response_sender, message) => {
                    if let Err(err) = self.update(message) {
                        log::error!("Failed to update infraction recorder: {err}");
                    }
                    response_sender.send(()).unwrap();
                }
                InfractionRecorderCommand::UpdateConfig(config) => {
                    log::info!(
                        "Config updated: authorized_speed={}, min_dist={}, max_dist={}, trigger_cooldown={}ms",
                        config.authorized_speed,
                        config.min_dist,
                        config.max_dist,
                        config.trigger_cooldown
                    );
                    self.authorized_speed = config.authorized_speed;
                    self.min_dist = config.min_dist;
                    self.max_dist = config.max_dist;
                    self.trigger_cooldown_ms = config.trigger_cooldown;
                }
            }
        }
    }
}

impl InfractionRecorderInner {
    const TARGET_PREFIX: &str = "EVENTS: TARGET: ";

    fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        uploader_port: ActorPort<InfractionUploaderCommand>,
        target_data_tx: broadcast::Sender<TargetData>,
        test_mode: bool,
    ) -> Self {
        Self {
            authorized_speed,
            min_dist: 0.0,
            max_dist: 10_000.0,
            trigger_cooldown_ms: 1000,
            photos_dir,
            uploader_port,
            target_data_tx,
            last_infraction: None,
            test_mode,
        }
    }

    fn update(&mut self, message: String) -> Result<()> {
        if !message.starts_with(Self::TARGET_PREFIX) {
            return Ok(());
        }
        let rest = message
            .strip_prefix(Self::TARGET_PREFIX)
            .unwrap();
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.len() != 3 {
            return Ok(());
        }
        let speed = parts[0].parse::<i16>().wrap_err("Failed to parse speed")?;
        let x = parts[1].parse::<i16>().wrap_err("Failed to parse x")?;
        let y = parts[2].parse::<i16>().wrap_err("Failed to parse y")?;
        let distance = ((x as f64).powi(2) + (y as f64).powi(2)).sqrt();

        let in_range = self.min_dist <= distance && distance <= self.max_dist;
        let over_speed = speed > self.authorized_speed;
        let cooldown_elapsed = match &self.last_infraction {
            Some(inf) => Utc::now().signed_duration_since(inf.datetime_taken) >= TimeDelta::milliseconds(self.trigger_cooldown_ms),
            None => true,
        };
        let triggered = in_range && over_speed && cooldown_elapsed;

        let target_data = TargetData { speed, x, y, distance, triggered };
        let _ = self.target_data_tx.send(target_data);

        if triggered {
            let infraction = Infraction {
                recorded_speed: speed,
                authorized_speed: self.authorized_speed,
                location: "Lorgues".to_string(),
                datetime_taken: Utc::now(),
            };
            log::info!("Infraction: {infraction:#?}");
            self.take_picture(&infraction)?;
            infraction.save_infraction_json(&self.photos_dir)?;
            let _ = self
                .uploader_port
                .send(InfractionUploaderCommand::NotifyInfraction);
            self.last_infraction = Some(infraction);
        }
        Ok(())
    }

    fn take_picture(&self, infraction: &Infraction) -> Result<()> {
        let photo_path = infraction.photo_path(&self.photos_dir);
        if self.test_mode {
            // Minimal valid 1x1 white JPEG
            #[rustfmt::skip]
            const DUMMY_JPEG: &[u8] = &[
                0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
                0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
                0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
                0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
                0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
                0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
                0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
                0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
                0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
                0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
                0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
                0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
                0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
                0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
                0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
                0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
                0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
                0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
                0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
                0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
                0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
                0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
                0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
                0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
                0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
                0x00, 0x00, 0x3F, 0x00, 0x7B, 0x94, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xD9,
            ];
            std::fs::write(&photo_path, DUMMY_JPEG)?;
            log::info!("Test mode: wrote dummy JPEG to {photo_path}");
            return Ok(());
        }

        let output = duct::cmd(
            "gphoto2",
            &[
                "--capture-image-and-download",
                "--force-overwrite",
                "--filename",
                photo_path.as_str(),
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

#[derive(Debug, Serialize, Deserialize)]
pub struct Infraction {
    pub recorded_speed: i16,
    pub authorized_speed: i16,
    pub location: String,
    pub datetime_taken: DateTime<Utc>,
}

impl Infraction {
    fn base_name(&self) -> String {
        self.datetime_taken.to_rfc3339()
    }

    pub fn photo_path(&self, photos_dir: &Utf8Path) -> Utf8PathBuf {
        photos_dir.join(format!("{}.jpg", self.base_name()))
    }

    pub fn infraction_path(&self, photos_dir: &Utf8Path) -> Utf8PathBuf {
        photos_dir.join(format!("{}.json", self.base_name()))
    }

    pub fn save_infraction_json(&self, photos_dir: &Utf8Path) -> Result<()> {
        let infraction_json = serde_json::to_string(self)?;
        std::fs::write(self.infraction_path(photos_dir), infraction_json)?;
        Ok(())
    }
}
