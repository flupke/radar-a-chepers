use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use eyre::{Context, Result, eyre};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, watch};

use crate::{
    actor::{Actor, ActorPort},
    infraction_uploader::{InfractionUploader, InfractionUploaderCommand},
    uploader_logger::UploaderLog,
};

const TARGET_PREFIX: &str = "EVENTS: TARGET: ";
const TRIGGER_PREFIX: &str = "EVENTS: TRIGGER: ";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawTarget {
    pub raw_speed_cm_s: i16,
    pub x: i16,
    pub y: i16,
}

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
    pub raw_speed_cm_s: i16,
    pub speed: i16,
    pub x: i16,
    pub y: i16,
    pub distance: f64,
    pub angle: f64,
    pub in_range: bool,
    pub in_aperture: bool,
    pub over_speed: bool,
    pub cooldown_elapsed: bool,
    pub capture_paused: bool,
    pub capture_in_progress: bool,
    pub would_trigger: bool,
    pub triggered: bool,
}

pub struct InfractionRecorder {
    port: ActorPort<InfractionRecorderCommand>,
    radar_input: RadarInput,
}

#[derive(Clone)]
pub struct RadarInput {
    target_tx: watch::Sender<Option<RawTarget>>,
    trigger_tx: mpsc::UnboundedSender<RawTarget>,
    uploader_log_tx: broadcast::Sender<UploaderLog>,
}

impl RadarInput {
    pub fn process_log_message(&self, message: String) {
        if is_target_message(&message) {
            match parse_raw_target_message(&message) {
                Ok(target) => {
                    let _ = self.target_tx.send(Some(target));
                }
                Err(err) => {
                    log::error!("Failed to parse radar target: {err}");
                }
            }
        } else if is_trigger_message(&message) {
            match parse_raw_trigger_message(&message) {
                Ok(target) => {
                    let _ = self.trigger_tx.send(target);
                }
                Err(err) => {
                    log::error!("Failed to parse radar trigger: {err}");
                }
            }
        } else {
            eprintln!("[radar firmware] {message}");
            let _ = self.uploader_log_tx.send(UploaderLog::info(message));
        }
    }
}

impl InfractionRecorder {
    pub fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        infraction_uploader: &InfractionUploader,
        target_data_tx: broadcast::Sender<TargetData>,
        uploader_log_tx: broadcast::Sender<UploaderLog>,
        test_mode: bool,
    ) -> Self {
        let (target_tx, target_rx) = watch::channel(None);
        let (trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        let radar_input = RadarInput {
            target_tx,
            trigger_tx,
            uploader_log_tx,
        };

        Self {
            port: InfractionRecorderInner::new(
                authorized_speed,
                photos_dir,
                infraction_uploader.port.clone(),
                target_data_tx,
                target_rx,
                trigger_rx,
                test_mode,
            )
            .start(),
            radar_input,
        }
    }

    pub fn port(&self) -> &ActorPort<InfractionRecorderCommand> {
        &self.port
    }

    pub fn radar_input(&self) -> RadarInput {
        self.radar_input.clone()
    }
}

pub enum InfractionRecorderCommand {
    UpdateConfig(RadarConfig),
}

struct InfractionRecorderInner {
    authorized_speed: i16,
    min_dist: f64,
    max_dist: f64,
    trigger_cooldown_ms: i64,
    aperture_angle: i16,
    capture_paused: bool,
    capture_in_progress: bool,
    last_capture_attempt_at: Option<DateTime<Utc>>,
    photos_dir: Utf8PathBuf,
    uploader_port: ActorPort<InfractionUploaderCommand>,
    target_data_tx: broadcast::Sender<TargetData>,
    target_rx: watch::Receiver<Option<RawTarget>>,
    trigger_rx: mpsc::UnboundedReceiver<RawTarget>,
    test_mode: bool,
}

impl Actor for InfractionRecorderInner {
    type Command = InfractionRecorderCommand;

    async fn event_loop(
        mut self,
        port: ActorPort<Self::Command>,
        mut command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) {
        loop {
            tokio::select! {
                command = command_receiver.recv() => {
                    let Some(command) = command else {
                        break;
                    };

                    match command {
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
                target_changed = self.target_rx.changed() => {
                    if target_changed.is_err() {
                        break;
                    }

                    let target = self.target_rx.borrow_and_update().clone();
                    if let Some(target) = target {
                        if let Err(err) = self.update_target(target, Some(&port)) {
                            log::error!("Failed to update infraction recorder: {err}");
                        }
                    }
                }
                trigger = self.trigger_rx.recv() => {
                    let Some(trigger) = trigger else {
                        break;
                    };

                    if let Err(err) = self.record_trigger(trigger, Some(&port)) {
                        log::error!("Failed to record radar trigger: {err}");
                    }
                }
            }
        }
    }
}

impl InfractionRecorderInner {
    fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        uploader_port: ActorPort<InfractionUploaderCommand>,
        target_data_tx: broadcast::Sender<TargetData>,
        target_rx: watch::Receiver<Option<RawTarget>>,
        trigger_rx: mpsc::UnboundedReceiver<RawTarget>,
        test_mode: bool,
    ) -> Self {
        Self {
            authorized_speed,
            min_dist: 0.0,
            max_dist: 10_000.0,
            trigger_cooldown_ms: 1000,
            aperture_angle: 90,
            capture_paused: false,
            capture_in_progress: false,
            photos_dir,
            uploader_port,
            target_data_tx,
            target_rx,
            trigger_rx,
            last_capture_attempt_at: None,
            test_mode,
        }
    }

    fn update_target(
        &mut self,
        target: RawTarget,
        _port: Option<&ActorPort<InfractionRecorderCommand>>,
    ) -> Result<()> {
        let target_data = self.target_data(target, false);
        let would_trigger = target_data.would_trigger;
        let _ = self.target_data_tx.send(target_data);

        if would_trigger && self.capture_paused {
            log::debug!("Capture paused: capture conditions met, not taking picture");
        }

        Ok(())
    }

    fn target_data(&self, target: RawTarget, triggered: bool) -> TargetData {
        let RawTarget {
            raw_speed_cm_s,
            x,
            y,
        } = target;
        let speed = raw_speed_cm_s_to_abs_kmh(raw_speed_cm_s);
        let distance = ((x as f64).powi(2) + (y as f64).powi(2)).sqrt();

        let in_range = self.min_dist <= distance && distance <= self.max_dist;
        let angle = (x as f64).atan2(y as f64).to_degrees().abs();
        let in_aperture = angle <= self.aperture_angle as f64 / 2.0;
        let over_speed = speed > self.authorized_speed;
        let now = Utc::now();
        let cooldown_elapsed = match self.last_capture_attempt_at {
            Some(last_attempt_at) => {
                now.signed_duration_since(last_attempt_at)
                    >= TimeDelta::milliseconds(self.trigger_cooldown_ms)
            }
            None => true,
        };
        let would_trigger = in_range && in_aperture && over_speed && cooldown_elapsed;

        TargetData {
            raw_speed_cm_s,
            speed,
            x,
            y,
            distance,
            angle,
            in_range,
            in_aperture,
            over_speed,
            cooldown_elapsed,
            capture_paused: self.capture_paused,
            capture_in_progress: self.capture_in_progress,
            would_trigger,
            triggered,
        }
    }

    fn record_trigger(
        &mut self,
        trigger: RawTarget,
        _port: Option<&ActorPort<InfractionRecorderCommand>>,
    ) -> Result<()> {
        let mut target_data = self.target_data(trigger, false);
        target_data.triggered = target_data.would_trigger && !self.capture_paused;
        let _ = self.target_data_tx.send(target_data.clone());

        if self.capture_paused {
            log::info!("Capture paused: ESP trigger received, not downloading picture");
            return Ok(());
        }

        if !target_data.would_trigger {
            log::info!("ESP trigger received, but server-side capture conditions no longer match");
            return Ok(());
        }

        let now = Utc::now();
        self.last_capture_attempt_at = Some(now);
        let infraction = Infraction {
            recorded_speed: target_data.speed,
            authorized_speed: self.authorized_speed,
            location: "Lorgues".to_string(),
            datetime_taken: now,
        };
        log::info!("Infraction: {infraction:#?}");

        if self.test_mode {
            write_test_photo(&self.photos_dir, &infraction)?;
        }
        infraction.save_infraction_json(&self.photos_dir)?;
        let _ = self
            .uploader_port
            .send(InfractionUploaderCommand::NotifyInfraction);

        Ok(())
    }
}

fn write_test_photo(photos_dir: &Utf8Path, infraction: &Infraction) -> Result<()> {
    let photo_path = infraction.photo_path(photos_dir);
    const TEST_PHOTO_JPEG: &[u8] = include_bytes!("test-photo.jpg");

    std::fs::write(&photo_path, TEST_PHOTO_JPEG)?;
    log::info!("Test mode: wrote test photo to {photo_path}");

    Ok(())
}

pub(crate) fn ensure_jpeg(photo_path: &Utf8Path) -> Result<()> {
    let data = std::fs::read(photo_path)?;
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Ok(());
    }

    Err(eyre!(
        "captured file is not a JPEG: {photo_path}. Check camera imagequality; first bytes are {:#X?}",
        &data[..data.len().min(8)]
    ))
}

fn is_target_message(message: &str) -> bool {
    message.starts_with(TARGET_PREFIX)
}

fn is_trigger_message(message: &str) -> bool {
    message.starts_with(TRIGGER_PREFIX)
}

fn parse_raw_target_message(message: &str) -> Result<RawTarget> {
    parse_raw_radar_message(message.strip_prefix(TARGET_PREFIX).unwrap())
}

fn parse_raw_trigger_message(message: &str) -> Result<RawTarget> {
    parse_raw_radar_message(message.strip_prefix(TRIGGER_PREFIX).unwrap())
}

fn parse_raw_radar_message(rest: &str) -> Result<RawTarget> {
    let parts: Vec<&str> = rest.split_whitespace().collect();
    if parts.len() != 3 {
        return Err(eyre!("expected 3 target fields, got {}", parts.len()));
    }

    Ok(RawTarget {
        raw_speed_cm_s: parts[0].parse::<i16>().wrap_err("Failed to parse speed")?,
        x: parts[1].parse::<i16>().wrap_err("Failed to parse x")?,
        y: parts[2].parse::<i16>().wrap_err("Failed to parse y")?,
    })
}

fn raw_speed_cm_s_to_abs_kmh(raw_speed_cm_s: i16) -> i16 {
    (f64::from(raw_speed_cm_s).abs() * 0.036).round() as i16
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
        let (_target_tx, target_rx) = watch::channel(None);
        let (_trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        let recorder = InfractionRecorderInner::new(
            authorized_speed,
            photos_dir.clone(),
            NoopUploader.start(),
            target_data_tx,
            target_rx,
            trigger_rx,
            true,
        );

        (temp_dir, photos_dir, recorder, target_data_rx)
    }

    fn test_infraction_recorder(
        authorized_speed: i16,
    ) -> (
        tempfile::TempDir,
        InfractionRecorder,
        broadcast::Receiver<TargetData>,
        broadcast::Receiver<UploaderLog>,
    ) {
        let temp_dir = tempfile::tempdir().unwrap();
        let photos_dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();
        let (target_data_tx, target_data_rx) = broadcast::channel(8);
        let (uploader_log_tx, uploader_log_rx) = broadcast::channel(8);
        let uploader = InfractionUploader::new(
            photos_dir.clone(),
            "http://localhost".to_string(),
            "api-key".to_string(),
        );
        let recorder = InfractionRecorder::new(
            authorized_speed,
            photos_dir,
            &uploader,
            target_data_tx,
            uploader_log_tx,
            true,
        );

        (temp_dir, recorder, target_data_rx, uploader_log_rx)
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

    fn raw_target(raw_speed_cm_s: i16, x: i16, y: i16) -> RawTarget {
        RawTarget {
            raw_speed_cm_s,
            x,
            y,
        }
    }

    async fn receive_target(target_data_rx: &mut broadcast::Receiver<TargetData>) -> TargetData {
        target_data_rx.recv().await.unwrap()
    }

    #[test]
    fn converts_rd03d_raw_speed_to_kmh() {
        assert_eq!(raw_speed_cm_s_to_abs_kmh(0), 0);
        assert_eq!(raw_speed_cm_s_to_abs_kmh(150), 5);
        assert_eq!(raw_speed_cm_s_to_abs_kmh(-150), 5);
        assert_eq!(raw_speed_cm_s_to_abs_kmh(2222), 80);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn target_messages_are_not_forwarded_as_uploader_logs() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, recorder, mut target_data_rx, mut uploader_log_rx) =
                    test_infraction_recorder(100);

                recorder
                    .radar_input()
                    .process_log_message("EVENTS: TARGET: 150 0 100".to_string());

                let target_data = receive_target(&mut target_data_rx).await;
                assert_eq!(target_data.speed, 5);
                assert!(matches!(
                    uploader_log_rx.try_recv(),
                    Err(broadcast::error::TryRecvError::Empty)
                ));
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn non_target_messages_are_forwarded_as_uploader_logs() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, recorder, mut target_data_rx, mut uploader_log_rx) =
                    test_infraction_recorder(100);

                recorder
                    .radar_input()
                    .process_log_message("camera disconnected".to_string());

                assert_eq!(
                    uploader_log_rx.try_recv().unwrap(),
                    UploaderLog::info("camera disconnected")
                );
                assert!(matches!(
                    target_data_rx.try_recv(),
                    Err(broadcast::error::TryRecvError::Empty)
                ));
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn trigger_messages_record_infractions_without_forwarding_logs() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (temp_dir, recorder, mut target_data_rx, mut uploader_log_rx) =
                    test_infraction_recorder(4);
                let photos_dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();

                recorder
                    .radar_input()
                    .process_log_message("EVENTS: TRIGGER: 150 0 100".to_string());

                let target_data = receive_target(&mut target_data_rx).await;
                assert_eq!(target_data.speed, 5);
                assert!(target_data.triggered);
                assert_eq!(saved_infractions(&photos_dir).len(), 1);
                assert!(matches!(
                    uploader_log_rx.try_recv(),
                    Err(broadcast::error::TryRecvError::Empty)
                ));
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn converts_raw_centimeters_per_second_before_recording_esp_trigger() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);

                recorder
                    .update_target(raw_target(150, 0, 100), None)
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 5);
                assert!(target_data.would_trigger);
                assert!(!target_data.triggered);
                assert_eq!(saved_infractions(&photos_dir).len(), 0);

                recorder
                    .record_trigger(raw_target(150, 0, 100), None)
                    .unwrap();

                let trigger_data = target_data_rx.try_recv().unwrap();
                assert_eq!(trigger_data.speed, 5);
                assert!(trigger_data.triggered);

                let infractions = saved_infractions(&photos_dir);
                assert_eq!(infractions.len(), 1);
                assert_eq!(infractions[0].recorded_speed, 5);
                assert_eq!(infractions[0].authorized_speed, 4);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn server_side_cooldown_still_guards_esp_triggers() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);
                recorder.trigger_cooldown_ms = 30_000;

                recorder
                    .record_trigger(raw_target(150, 0, 100), None)
                    .unwrap();
                recorder
                    .record_trigger(raw_target(200, 0, 100), None)
                    .unwrap();

                let first_target = target_data_rx.try_recv().unwrap();
                let second_target = target_data_rx.try_recv().unwrap();
                assert!(first_target.triggered);
                assert!(!second_target.triggered);
                assert!(!second_target.cooldown_elapsed);
                assert_eq!(saved_infractions(&photos_dir).len(), 1);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn negative_raw_speed_can_trigger() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);

                recorder
                    .update_target(raw_target(-150, 0, 100), None)
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 5);
                assert!(target_data.would_trigger);
                assert!(!target_data.triggered);

                recorder
                    .record_trigger(raw_target(-150, 0, 100), None)
                    .unwrap();

                let trigger_data = target_data_rx.try_recv().unwrap();
                assert_eq!(trigger_data.speed, 5);
                assert!(trigger_data.triggered);

                let infractions = saved_infractions(&photos_dir);
                assert_eq!(infractions.len(), 1);
                assert_eq!(infractions[0].recorded_speed, 5);
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
                    .record_trigger(raw_target(150, 0, 100), None)
                    .unwrap();
                recorder
                    .update_target(raw_target(200, 0, 100), None)
                    .unwrap();

                let first_target = target_data_rx.try_recv().unwrap();
                let second_target = target_data_rx.try_recv().unwrap();
                assert!(first_target.triggered);
                assert_eq!(first_target.speed, 5);
                assert!(!second_target.triggered);
                assert!(!second_target.cooldown_elapsed);
                assert_eq!(second_target.speed, 7);

                assert_eq!(saved_infractions(&photos_dir).len(), 1);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn failed_capture_attempt_consumes_trigger_cooldown() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, _photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);
                recorder.trigger_cooldown_ms = 30_000;
                recorder.photos_dir = recorder.photos_dir.join("missing");

                let err = recorder
                    .record_trigger(raw_target(150, 0, 100), None)
                    .unwrap_err();
                assert!(
                    err.to_string().contains("No such file")
                        || err.to_string().contains("not found")
                );

                recorder
                    .update_target(raw_target(200, 0, 100), None)
                    .unwrap();

                let first_target = target_data_rx.try_recv().unwrap();
                let second_target = target_data_rx.try_recv().unwrap();
                assert!(first_target.triggered);
                assert!(!second_target.triggered);
                assert!(!second_target.cooldown_elapsed);
            })
            .await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn photo_retrieval_backlog_does_not_block_new_triggers() {
        let local = tokio::task::LocalSet::new();

        local
            .run_until(async {
                let (_temp_dir, photos_dir, mut recorder, mut target_data_rx) = test_recorder(4);
                recorder.capture_in_progress = true;
                recorder.last_capture_attempt_at = Some(Utc::now() - TimeDelta::seconds(60));

                recorder
                    .record_trigger(raw_target(200, 0, 100), None)
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 7);
                assert!(target_data.capture_in_progress);
                assert!(target_data.triggered);
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
                    .update_target(raw_target(2222, 0, 100), None)
                    .unwrap();

                let target_data = target_data_rx.try_recv().unwrap();
                assert_eq!(target_data.speed, 80);
                assert!(!target_data.triggered);
                assert_eq!(std::fs::read_dir(&photos_dir).unwrap().count(), 0);
            })
            .await;
    }
}
