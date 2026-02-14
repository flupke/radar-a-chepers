use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use eyre::{Context, Result};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};

use crate::{
    actor::{Actor, ActorPort},
    infraction_uploader::{InfractionUploader, InfractionUploaderCommand},
};

pub struct InfractionRecorder {
    port: ActorPort<InfractionRecorderCommand>,
}

impl InfractionRecorder {
    pub fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        infraction_uploader: &InfractionUploader,
    ) -> Self {
        Self {
            port: InfractionRecorderInner::new(
                authorized_speed,
                photos_dir,
                infraction_uploader.port.clone(),
            )
            .start(),
        }
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

enum InfractionRecorderCommand {
    ProcessLogMessage(oneshot::Sender<()>, String),
}

struct InfractionRecorderInner {
    authorized_speed: i16,
    last_infraction: Option<Infraction>,
    photos_dir: Utf8PathBuf,
    uploader_port: ActorPort<InfractionUploaderCommand>,
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
            }
        }
    }
}

impl InfractionRecorderInner {
    const MAX_SPEED_PREFIX: &str = "EVENTS: MAX_SPEED: ";

    fn new(
        authorized_speed: i16,
        photos_dir: Utf8PathBuf,
        uploader_port: ActorPort<InfractionUploaderCommand>,
    ) -> Self {
        Self {
            authorized_speed,
            photos_dir,
            uploader_port,
            last_infraction: None,
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
            infraction.save_infraction_json(&self.photos_dir)?;
            let _ = self
                .uploader_port
                .send(InfractionUploaderCommand::NotifyInfraction);
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
