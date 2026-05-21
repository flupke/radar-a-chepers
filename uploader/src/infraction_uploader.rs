use camino::{Utf8Path, Utf8PathBuf};
use eyre::{Result, eyre};
use reqwest::{Client, multipart};
use tokio::sync::mpsc;

use crate::actor::{Actor, ActorPort};
use crate::infraction_recorder::{Infraction, ensure_jpeg};

const CAMERA_DOWNLOADS_DIR: &str = "camera-downloads";

pub struct InfractionUploader {
    pub port: ActorPort<InfractionUploaderCommand>,
}

impl InfractionUploader {
    pub fn new(infractions_dir: Utf8PathBuf, api_url: String, api_key: String) -> Self {
        Self::new_with_photo_retrieval(infractions_dir, api_url, api_key, true)
    }

    pub fn new_with_photo_retrieval(
        infractions_dir: Utf8PathBuf,
        api_url: String,
        api_key: String,
        retrieve_camera_photos: bool,
    ) -> Self {
        Self {
            port: InfractionUploaderInner::new(
                infractions_dir,
                api_url,
                api_key,
                retrieve_camera_photos,
            )
            .start(),
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
    retrieve_camera_photos: bool,
}

impl InfractionUploaderInner {
    fn new(
        infractions_dir: Utf8PathBuf,
        api_url: String,
        api_key: String,
        retrieve_camera_photos: bool,
    ) -> Self {
        Self {
            infractions_dir,
            api_url,
            api_key,
            client: Client::new(),
            retrieve_camera_photos,
        }
    }

    async fn handle_notification(&self) {
        if self.retrieve_camera_photos {
            let infractions_dir = self.infractions_dir.clone();
            match tokio::task::spawn_blocking(move || retrieve_new_camera_photos(&infractions_dir))
                .await
            {
                Ok(Ok(attached_count)) => {
                    if attached_count > 0 {
                        log::info!("Attached {attached_count} downloaded camera photo(s)");
                    }
                }
                Ok(Err(err)) => {
                    log::error!("Failed to retrieve camera photos: {err}");
                }
                Err(err) => {
                    log::error!("Camera photo retrieval task failed: {err}");
                }
            }
        }

        self.upload_pending().await;
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
                && path.with_extension("jpg").exists()
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
            log::info!("Kept uploaded photo at {}", photo_path.display());
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
                    self.handle_notification().await;
                }
                InfractionUploaderCommand::Shutdown => {
                    return;
                }
            }
        }
    }
}

fn retrieve_new_camera_photos(infractions_dir: &Utf8Path) -> Result<usize> {
    let downloads_dir = camera_downloads_dir(infractions_dir);
    std::fs::create_dir_all(&downloads_dir)?;

    let output = duct::cmd("gphoto2", &["--get-all-files", "--new", "--skip-existing"])
        .dir(downloads_dir.as_std_path())
        .stderr_to_stdout()
        .stdout_capture()
        .unchecked()
        .run()?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(eyre!(
            "gphoto2 download command failed with status {}:\n{}",
            output.status,
            stdout
        ));
    }

    attach_downloaded_photos(infractions_dir, &downloads_dir)
}

fn attach_downloaded_photos(infractions_dir: &Utf8Path, downloads_dir: &Utf8Path) -> Result<usize> {
    let pending_infractions = pending_infraction_jsons(infractions_dir)?;
    if pending_infractions.is_empty() {
        return Ok(0);
    }

    let downloaded_photos = downloaded_photos(downloads_dir)?;
    let attach_count = pending_infractions.len().min(downloaded_photos.len());

    for (json_path, downloaded_photo) in pending_infractions
        .into_iter()
        .zip(downloaded_photos)
        .take(attach_count)
    {
        let downloaded_photo_path = Utf8PathBuf::from_path_buf(downloaded_photo.clone())
            .map_err(|path| eyre!("downloaded photo path is not UTF-8: {}", path.display()))?;
        ensure_jpeg(&downloaded_photo_path)?;

        let photo_path = json_path.with_extension("jpg");
        std::fs::rename(&downloaded_photo, &photo_path)?;
    }

    Ok(attach_count)
}

fn pending_infraction_jsons(infractions_dir: &Utf8Path) -> Result<Vec<std::path::PathBuf>> {
    let mut paths = std::fs::read_dir(infractions_dir)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .filter(|path| !path.with_extension("jpg").exists())
        .collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

fn downloaded_photos(downloads_dir: &Utf8Path) -> Result<Vec<std::path::PathBuf>> {
    let mut paths = std::fs::read_dir(downloads_dir)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| {
                    extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg")
                })
        })
        .collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

fn camera_downloads_dir(infractions_dir: &Utf8Path) -> Utf8PathBuf {
    infractions_dir.join(CAMERA_DOWNLOADS_DIR)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    const TEST_JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0x00];

    #[test]
    fn attaches_downloaded_photos_to_pending_infractions_in_order() {
        let temp_dir = tempfile::tempdir().unwrap();
        let infractions_dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();
        let downloads_dir = camera_downloads_dir(&infractions_dir);
        std::fs::create_dir_all(&downloads_dir).unwrap();

        let first = Infraction {
            recorded_speed: 42,
            authorized_speed: 30,
            location: "Lorgues".to_string(),
            datetime_taken: Utc::now() - chrono::Duration::seconds(1),
        };
        let second = Infraction {
            recorded_speed: 45,
            authorized_speed: 30,
            location: "Lorgues".to_string(),
            datetime_taken: Utc::now(),
        };
        first.save_infraction_json(&infractions_dir).unwrap();
        second.save_infraction_json(&infractions_dir).unwrap();
        std::fs::write(downloads_dir.join("DSC_0001.JPG"), TEST_JPEG).unwrap();
        std::fs::write(downloads_dir.join("DSC_0002.JPG"), TEST_JPEG).unwrap();

        assert_eq!(
            attach_downloaded_photos(&infractions_dir, &downloads_dir).unwrap(),
            2
        );
        assert!(first.photo_path(&infractions_dir).exists());
        assert!(second.photo_path(&infractions_dir).exists());
        assert!(!downloads_dir.join("DSC_0001.JPG").exists());
        assert!(!downloads_dir.join("DSC_0002.JPG").exists());
    }

    #[test]
    fn leaves_extra_downloaded_photos_for_later_triggers() {
        let temp_dir = tempfile::tempdir().unwrap();
        let infractions_dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();
        let downloads_dir = camera_downloads_dir(&infractions_dir);
        std::fs::create_dir_all(&downloads_dir).unwrap();

        let infraction = Infraction {
            recorded_speed: 42,
            authorized_speed: 30,
            location: "Lorgues".to_string(),
            datetime_taken: Utc::now(),
        };
        infraction.save_infraction_json(&infractions_dir).unwrap();
        std::fs::write(downloads_dir.join("DSC_0001.JPG"), TEST_JPEG).unwrap();
        std::fs::write(downloads_dir.join("DSC_0002.JPG"), TEST_JPEG).unwrap();

        assert_eq!(
            attach_downloaded_photos(&infractions_dir, &downloads_dir).unwrap(),
            1
        );
        assert!(infraction.photo_path(&infractions_dir).exists());
        assert!(!downloads_dir.join("DSC_0001.JPG").exists());
        assert!(downloads_dir.join("DSC_0002.JPG").exists());
    }
}
