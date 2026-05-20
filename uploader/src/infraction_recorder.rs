use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use eyre::{Context, Result, eyre};
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
    pub aperture_angle: i16,
    pub capture_paused: bool,
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
    aperture_angle: i16,
    capture_paused: bool,
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
                        "Config updated: authorized_speed={}, min_dist={}, max_dist={}, trigger_cooldown={}ms, aperture_angle={}, capture_paused={}",
                        config.authorized_speed,
                        config.min_dist,
                        config.max_dist,
                        config.trigger_cooldown,
                        config.aperture_angle,
                        config.capture_paused
                    );
                    self.authorized_speed = config.authorized_speed;
                    self.min_dist = config.min_dist;
                    self.max_dist = config.max_dist;
                    self.trigger_cooldown_ms = config.trigger_cooldown;
                    self.aperture_angle = config.aperture_angle;
                    self.capture_paused = config.capture_paused;
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
            aperture_angle: 90,
            capture_paused: false,
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
        let rest = message.strip_prefix(Self::TARGET_PREFIX).unwrap();
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.len() != 3 {
            return Ok(());
        }
        let raw_speed_cm_s = parts[0].parse::<i16>().wrap_err("Failed to parse speed")?;
        let speed = raw_speed_cm_s_to_kmh(raw_speed_cm_s);
        let x = parts[1].parse::<i16>().wrap_err("Failed to parse x")?;
        let y = parts[2].parse::<i16>().wrap_err("Failed to parse y")?;
        let distance = ((x as f64).powi(2) + (y as f64).powi(2)).sqrt();

        let in_range = self.min_dist <= distance && distance <= self.max_dist;
        let angle = (x as f64).atan2(y as f64).to_degrees().abs();
        let in_aperture = angle <= self.aperture_angle as f64 / 2.0;
        let over_speed = speed > self.authorized_speed;
        let cooldown_elapsed = match &self.last_infraction {
            Some(inf) => {
                Utc::now().signed_duration_since(inf.datetime_taken)
                    >= TimeDelta::milliseconds(self.trigger_cooldown_ms)
            }
            None => true,
        };
        let would_trigger = in_range && in_aperture && over_speed && cooldown_elapsed;
        let triggered = would_trigger && !self.capture_paused;

        let target_data = TargetData {
            speed,
            x,
            y,
            distance,
            triggered,
        };
        let _ = self.target_data_tx.send(target_data);

        if would_trigger && self.capture_paused {
            log::debug!("Capture paused: capture conditions met, not taking picture");
        }

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
            const TEST_PHOTO_JPEG: &[u8] = include_bytes!("test-photo.jpg");

            std::fs::write(&photo_path, TEST_PHOTO_JPEG)?;
            log::info!("Test mode: wrote test photo to {photo_path}");
            return Ok(());
        }

        let output = duct::cmd(
            "gphoto2",
            &[
                "--set-config",
                "imagequality=JPEG Fine",
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
            return Err(eyre!(
                "gphoto2 command failed with status {}:\n{}",
                output.status,
                stdout
            ));
        }

        if !photo_path.exists() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            return Err(eyre!(
                "gphoto2 completed successfully but did not create {photo_path}:\n{}",
                stdout
            ));
        }
        self.ensure_jpeg(&photo_path)?;
        log::info!("Saved photo to {photo_path}");

        Ok(())
    }

    fn ensure_jpeg(&self, photo_path: &Utf8Path) -> Result<()> {
        let data = std::fs::read(photo_path)?;
        if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
            return Ok(());
        }

        Err(eyre!(
            "captured file is not a JPEG: {photo_path}. Check camera imagequality; first bytes are {:#X?}",
            &data[..data.len().min(8)]
        ))
    }
}

fn raw_speed_cm_s_to_kmh(raw_speed_cm_s: i16) -> i16 {
    (f64::from(raw_speed_cm_s) * 0.036).round() as i16
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
        self.datetime_taken.format("%Y%m%dT%H%M%S%.fZ").to_string()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        actor::{Actor, ActorPort},
        infraction_uploader::InfractionUploaderCommand,
    };
    use tokio::sync::mpsc;

    struct NoopUploader;

    impl Actor for NoopUploader {
        type Command = InfractionUploaderCommand;

        async fn event_loop(
            self,
            _port: ActorPort<Self::Command>,
            mut command_receiver: mpsc::UnboundedReceiver<Self::Command>,
        ) {
            while command_receiver.recv().await.is_some() {}
        }
    }

    fn test_recorder(
        authorized_speed: i16,
    ) -> (
        tempfile::TempDir,
        Utf8PathBuf,
        InfractionRecorderInner,
        broadcast::Receiver<TargetData>,
    ) {
        let temp_dir = tempfile::tempdir().unwrap();
        let photos_dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();
        let (target_data_tx, target_data_rx) = broadcast::channel(8);
        let recorder = InfractionRecorderInner::new(
            authorized_speed,
            photos_dir.clone(),
            NoopUploader.start(),
            target_data_tx,
            true,
        );

        (temp_dir, photos_dir, recorder, target_data_rx)
    }

    fn saved_infractions(photos_dir: &Utf8Path) -> Vec<Infraction> {
        std::fs::read_dir(photos_dir)
            .unwrap()
            .flatten()
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
            .map(|entry| {
                let json = std::fs::read_to_string(entry.path()).unwrap();
                serde_json::from_str(&json).unwrap()
            })
            .collect()
    }

    #[test]
    fn converts_rd03d_raw_speed_to_kmh() {
        assert_eq!(raw_speed_cm_s_to_kmh(0), 0);
        assert_eq!(raw_speed_cm_s_to_kmh(150), 5);
        assert_eq!(raw_speed_cm_s_to_kmh(2222), 80);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn converts_raw_centimeters_per_second_before_triggering() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);

                recorder
                    .update("EVENTS: TARGET: 150 0 100".to_string())
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 5);
                assert!(target_data.triggered);

                let infractions = saved_infractions(&photos_dir);
                assert_eq!(infractions.len(), 1);
                assert_eq!(infractions[0].recorded_speed, 5);
                assert_eq!(infractions[0].authorized_speed, 4);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn trigger_cooldown_blocks_repeat_infractions() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);
                recorder.trigger_cooldown_ms = 30_000;

                recorder
                    .update("EVENTS: TARGET: 150 0 100".to_string())
                    .unwrap();
                recorder
                    .update("EVENTS: TARGET: 200 0 100".to_string())
                    .unwrap();

                let first_target = target_data_rx.try_recv().unwrap();
                let second_target = target_data_rx.try_recv().unwrap();
                assert!(first_target.triggered);
                assert_eq!(first_target.speed, 5);
                assert!(!second_target.triggered);
                assert_eq!(second_target.speed, 7);

                assert_eq!(saved_infractions(&photos_dir).len(), 1);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn capture_paused_still_sends_target_data_without_taking_picture() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(25);
                recorder.capture_paused = true;

                recorder
                    .update("EVENTS: TARGET: 2222 0 100".to_string())
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 80);
                assert!(!target_data.triggered);
                assert_eq!(std::fs::read_dir(&photos_dir).unwrap().count(), 0);
            })
            .await;
    }
}
