use camino::Utf8PathBuf;
use reqwest::{Client, multipart};
use tokio::sync::mpsc;

use crate::actor::{Actor, ActorPort};
use crate::infraction_recorder::Infraction;

pub struct InfractionUploader {
    pub port: ActorPort<InfractionUploaderCommand>,
}

impl InfractionUploader {
    pub fn new(infractions_dir: Utf8PathBuf, api_url: String, api_key: String) -> Self {
        Self {
            port: InfractionUploaderInner::new(infractions_dir, api_url, api_key).start(),
        }
    }
}

pub enum InfractionUploaderCommand {
    NotifyInfraction,
    Shutdown,
}

struct InfractionUploaderInner {
    infractions_dir: Utf8PathBuf,
    api_url: String,
    api_key: String,
    client: Client,
}

impl InfractionUploaderInner {
    fn new(infractions_dir: Utf8PathBuf, api_url: String, api_key: String) -> Self {
        Self {
            infractions_dir,
            api_url,
            api_key,
            client: Client::new(),
        }
    }

    async fn upload_pending(&self) {
        let entries = match std::fs::read_dir(&self.infractions_dir) {
            Ok(entries) => entries,
            Err(err) => {
                log::error!("Failed to read infractions dir: {err}");
                return;
            }
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "json")
                && let Err(err) = self.upload_one(&path).await
            {
                log::error!("Failed to upload {}: {err}", path.display());
            }
        }
    }

    async fn upload_one(&self, json_path: &std::path::Path) -> eyre::Result<()> {
        let json_data = std::fs::read_to_string(json_path)?;
        let _infraction: Infraction = serde_json::from_str(&json_data)?;

        let photo_path = json_path.with_extension("jpg");
        let photo_data = std::fs::read(&photo_path)?;
        let filename = photo_path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        let form = multipart::Form::new()
            .part(
                "photo",
                multipart::Part::bytes(photo_data)
                    .file_name(filename)
                    .mime_str("image/jpeg")?,
            )
            .text("infraction", json_data);

        let resp = self
            .client
            .post(format!("{}/api/photos", self.api_url))
            .header("x-api-key", &self.api_key)
            .multipart(form)
            .send()
            .await?;

        if resp.status().is_success() {
            let body: serde_json::Value = resp.json().await?;
            log::info!("Uploaded infraction #{}", body["infraction_id"]);
            std::fs::remove_file(json_path)?;
            std::fs::remove_file(photo_path)?;
        } else {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(eyre::eyre!("API returned {status}: {body}"));
        }

        Ok(())
    }
}

impl Actor for InfractionUploaderInner {
    type Command = InfractionUploaderCommand;

    async fn event_loop(
        self,
        _port: ActorPort<Self::Command>,
        mut command_receiver: mpsc::UnboundedReceiver<Self::Command>,
    ) {
        while let Some(command) = command_receiver.recv().await {
            match command {
                InfractionUploaderCommand::NotifyInfraction => {
                    self.upload_pending().await;
                }
                InfractionUploaderCommand::Shutdown => {
                    return;
                }
            }
        }
    }
}
