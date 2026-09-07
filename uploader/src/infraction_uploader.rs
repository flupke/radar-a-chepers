use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, TimeDelta, Utc};
use eyre::{Result, WrapErr, eyre};
use reqwest::{Client, multipart};
use std::{collections::HashMap, io::Read, time::Duration};
use tokio::sync::mpsc;

use crate::actor::{Actor, ActorPort};
use crate::infraction_recorder::{Infraction, ensure_jpeg};

const CAMERA_DOWNLOADS_DIR: &str = "camera-downloads";
const INCOMPLETE_DOWNLOADS_PREFIX: &str = ".incomplete-";
const CAMERA_FILENAME_PATTERN: &str = "./%F/%f.%C";
const RETRY_INTERVAL: Duration = Duration::from_secs(10);
const UPLOAD_TIMEOUT: Duration = Duration::from_secs(30);
const CAMERA_TIMEOUT: Duration = Duration::from_secs(60);
// The camera clock must be synchronized with the Pi. EXIF's own timestamp
// precision is accounted for separately from transport/shutter tolerance.
const PHOTO_TIME_TOLERANCE: TimeDelta = TimeDelta::milliseconds(500);

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
            client: Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(UPLOAD_TIMEOUT)
                .build()
                .expect("valid HTTP client configuration"),
            retrieve_camera_photos,
        }
    }

    async fn handle_notification(&self) {
        if self.retrieve_camera_photos && camera_work_pending(&self.infractions_dir) {
            match retrieve_new_camera_photos(&self.infractions_dir).await {
                Ok(attached_count) => {
                    if attached_count > 0 {
                        log::info!("Attached {attached_count} downloaded camera photo(s)");
                    }
                }
                Err(err) => {
                    log::error!("Failed to retrieve camera photos: {err}");
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
                let connection_unavailable = err
                    .downcast_ref::<reqwest::Error>()
                    .is_some_and(|error| error.is_timeout() || error.is_connect());
                log::error!("Failed to upload {}: {err}", path.display());
                if connection_unavailable {
                    // Avoid spending one full timeout per queued file before
                    // returning to camera retrieval and the retry interval.
                    break;
                }
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
            .header(
                "x-capture-id",
                json_path
                    .file_stem()
                    .and_then(|stem| stem.to_str())
                    .ok_or_else(|| eyre!("invalid capture filename"))?,
            )
            .multipart(form)
            .send()
            .await?;

        if resp.status().is_success() {
            let body: serde_json::Value = resp.json().await?;
            log::info!("Uploaded infraction #{}", body["infraction_id"]);
            // Retain capture history when retiring the queue entry. Matching
            // must still consider an earlier capture after it was uploaded.
            std::fs::rename(json_path, json_path.with_extension("uploaded"))?;
            log::info!("Kept uploaded photo at {}", photo_path.display());
        } else {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(eyre::eyre!("API returned {status}: {body}"));
        }

        Ok(())
    }
}

fn camera_work_pending(infractions_dir: &Utf8Path) -> bool {
    // Poll the camera only while a capture still needs its photo.
    std::fs::read_dir(infractions_dir).is_ok_and(|entries| {
        entries.flatten().any(|entry| {
            let path = entry.path();
            path.extension().is_some_and(|ext| ext == "json")
                && !path.with_extension("jpg").exists()
        })
    })
}

impl Actor for InfractionUploaderInner {
    type Command = InfractionUploaderCommand;

    async fn event_loop(self, mut command_receiver: mpsc::UnboundedReceiver<Self::Command>) {
        // The first tick processes files left by a restart. Subsequent ticks
        // retry failures and photos that were not ready at trigger time.
        let mut retry = tokio::time::interval(RETRY_INTERVAL);
        retry.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                _ = retry.tick() => {}
                command = command_receiver.recv() => match command {
                    Some(InfractionUploaderCommand::NotifyInfraction) => {}
                    Some(InfractionUploaderCommand::Shutdown) | None => return,
                },
            }
            // A scan handles all pending captures, including notifications
            // that arrived while the previous scan was busy.
            while let Ok(command) = command_receiver.try_recv() {
                if matches!(command, InfractionUploaderCommand::Shutdown) {
                    return;
                }
            }
            self.handle_notification().await;
        }
    }
}

async fn retrieve_new_camera_photos(infractions_dir: &Utf8Path) -> Result<usize> {
    let mut command = tokio::process::Command::new("gphoto2");
    retrieve_camera_photos_with_command(infractions_dir, &mut command).await
}

async fn retrieve_camera_photos_with_command(
    infractions_dir: &Utf8Path,
    command: &mut tokio::process::Command,
) -> Result<usize> {
    let downloads_dir = camera_downloads_dir(infractions_dir);
    std::fs::create_dir_all(&downloads_dir)?;
    quarantine_incomplete_downloads(&downloads_dir)?;
    // Nikon does not mark downloaded files for --new. Keep originals at
    // stable camera-folder/filename paths so --skip-existing works before
    // transfer. Date substitutions cannot be resolved until after transfer.
    command
        .args([
            "--get-all-files",
            "--skip-existing",
            "--filename",
            CAMERA_FILENAME_PATTERN,
        ])
        .current_dir(&downloads_dir);
    match camera_command_output(command, CAMERA_TIMEOUT).await {
        Ok(output) if output.status.success() => {}
        Ok(output) => log::error!(
            "gphoto2 download command failed with status {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr),
        ),
        Err(error) => log::error!("Failed to download camera photos: {error:#}"),
    }
    // A killed or failed command may have saved both complete and partial
    // files. Retain partial files separately so a retry can replace them.
    quarantine_incomplete_downloads(&downloads_dir)?;
    attach_downloaded_photos(infractions_dir, &downloads_dir)
}

fn quarantine_incomplete_downloads(downloads: &Utf8Path) -> Result<()> {
    for path in downloaded_photos(downloads)? {
        let utf8_path =
            Utf8Path::from_path(&path).ok_or_else(|| eyre!("non-UTF-8 camera filename"))?;
        if let Err(error) = ensure_jpeg(utf8_path) {
            if error.downcast_ref::<std::io::Error>().is_some() {
                return Err(error);
            }
            let parent = path
                .parent()
                .ok_or_else(|| eyre!("missing camera cache directory"))?;
            let quarantine = tempfile::Builder::new()
                .prefix(INCOMPLETE_DOWNLOADS_PREFIX)
                .tempdir_in(parent)?
                .keep();
            let destination = quarantine.join(
                path.file_name()
                    .ok_or_else(|| eyre!("missing camera filename"))?,
            );
            std::fs::rename(&path, &destination)?;
            log::warn!(
                "Retained incomplete camera download at {}; its original cache path can now be downloaded again: {error}",
                destination.display()
            );
        }
    }
    Ok(())
}

async fn camera_command_output(
    command: &mut tokio::process::Command,
    timeout: Duration,
) -> Result<std::process::Output> {
    // Dropping the output future on timeout kills gphoto2 as well, releasing
    // the camera USB connection before a later retry.
    command.kill_on_drop(true);
    tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| eyre!("camera download timed out after {}s", timeout.as_secs()))?
        .map_err(Into::into)
}

fn attach_downloaded_photos(infractions_dir: &Utf8Path, downloads_dir: &Utf8Path) -> Result<usize> {
    attach_downloaded_photos_at(infractions_dir, downloads_dir, Utc::now())
}

fn attach_downloaded_photos_at(
    infractions_dir: &Utf8Path,
    downloads_dir: &Utf8Path,
    now: DateTime<Utc>,
) -> Result<usize> {
    let captures = capture_records(infractions_dir)?;
    if !captures.iter().any(CaptureRecord::needs_photo) {
        return Ok(0);
    }

    let mut photos: Vec<(std::path::PathBuf, PhotoCaptureTime)> = Vec::new();
    let mut timestamp_groups: HashMap<PhotoCaptureTime, Vec<usize>> = HashMap::new();
    for path in downloaded_photos(downloads_dir)? {
        let time = match photo_capture_time(&path) {
            Ok(time) => time,
            Err(error) => {
                log::warn!(
                    "Leaving camera photo {} unmatched: {error:#}",
                    path.display()
                );
                continue;
            }
        };
        let group = timestamp_groups.entry(time).or_default();
        let mut duplicate = false;
        for &index in group.iter() {
            if identical_photos(&path, &photos[index].0)? {
                duplicate = true;
                break;
            }
        }
        if !duplicate {
            group.push(photos.len());
            photos.push((path, time));
        }
    }

    // Compute all candidates before moving anything. Removing successful
    // matches must not make an ambiguous capture appear unambiguous later.
    let candidates: Vec<Vec<usize>> = photos
        .iter()
        .map(|(_, time)| {
            captures
                .iter()
                .enumerate()
                .filter_map(|(index, capture)| {
                    time.includes(capture.datetime_taken).then_some(index)
                })
                .collect()
        })
        .collect();
    let mut photo_counts = vec![0; captures.len()];
    for matches in &candidates {
        for &index in matches {
            photo_counts[index] += 1;
        }
    }
    let mut attached = 0;
    for ((path, time), matches) in photos.iter().zip(&candidates) {
        // Wait until all possible trigger receipt times in this photo's
        // matching window have passed before declaring the match unique.
        if now <= time.start + time.precision + PHOTO_TIME_TOLERANCE {
            continue;
        }
        if let [index] = matches.as_slice()
            && photo_counts[*index] == 1
            && captures[*index].needs_photo()
        {
            // Preserve the cache original for gphoto2's pre-transfer skip.
            std::fs::hard_link(path, captures[*index].path.with_extension("jpg"))?;
            attached += 1;
        } else {
            log::warn!(
                "Leaving camera photo {} unmatched: no unique pending capture within its EXIF time window; check camera clock and capture history",
                path.display()
            );
        }
    }
    Ok(attached)
}

fn identical_photos(first: &std::path::Path, second: &std::path::Path) -> Result<bool> {
    let mut first = std::fs::File::open(first)?;
    let mut second = std::fs::File::open(second)?;
    if first.metadata()?.len() != second.metadata()?.len() {
        return Ok(false);
    }
    // Only compare bytes for same-time candidates. This lets flat downloads
    // from older versions coexist with their new folder-cache copies without
    // interpreting two genuinely different photos as one.
    let mut first_buffer = [0; 16 * 1024];
    let mut second_buffer = [0; 16 * 1024];
    loop {
        let count = first.read(&mut first_buffer)?;
        if count == 0 {
            return Ok(true);
        }
        second.read_exact(&mut second_buffer[..count])?;
        if first_buffer[..count] != second_buffer[..count] {
            return Ok(false);
        }
    }
}

struct CaptureRecord {
    path: std::path::PathBuf,
    datetime_taken: DateTime<Utc>,
}

impl CaptureRecord {
    fn needs_photo(&self) -> bool {
        self.path.extension().is_some_and(|ext| ext == "json")
            && !self.path.with_extension("jpg").exists()
    }
}

fn capture_records(infractions_dir: &Utf8Path) -> Result<Vec<CaptureRecord>> {
    let mut captures = Vec::new();
    for entry in std::fs::read_dir(infractions_dir)? {
        let path = entry?.path();
        if path
            .extension()
            .is_some_and(|ext| ext == "json" || ext == "uploaded")
        {
            let infraction: Infraction = serde_json::from_slice(&std::fs::read(&path)?)
                .wrap_err_with(|| {
                    format!(
                        "invalid capture metadata {}; cannot safely match camera photos",
                        path.display()
                    )
                })?;
            captures.push(CaptureRecord {
                path,
                datetime_taken: infraction.datetime_taken,
            });
        }
    }
    Ok(captures)
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
struct PhotoCaptureTime {
    start: DateTime<Utc>,
    precision: TimeDelta,
}

impl PhotoCaptureTime {
    fn includes(&self, capture: DateTime<Utc>) -> bool {
        capture >= self.start - PHOTO_TIME_TOLERANCE
            && capture < self.start + self.precision + PHOTO_TIME_TOLERANCE
    }
}

fn photo_capture_time(path: &std::path::Path) -> Result<PhotoCaptureTime> {
    let utf8_path = Utf8Path::from_path(path).ok_or_else(|| eyre!("non-UTF-8 photo path"))?;
    ensure_jpeg(utf8_path)?;
    let file = std::fs::File::open(path)?;
    let exif = exif::Reader::new().read_from_container(&mut std::io::BufReader::new(file))?;
    let date = exif_ascii(&exif, exif::Tag::DateTimeOriginal)?
        .ok_or_else(|| eyre!("missing EXIF DateTimeOriginal"))?;
    // Older cameras omit OffsetTimeOriginal; those cameras must use UTC.
    let offset = exif_ascii(&exif, exif::Tag::OffsetTimeOriginal)?.unwrap_or("+00:00");
    if date.len() != 19 || offset.len() != 6 {
        return Err(eyre!("invalid EXIF capture timestamp"));
    }
    let mut start = DateTime::parse_from_str(&format!("{date} {offset}"), "%Y:%m:%d %H:%M:%S %:z")?
        .with_timezone(&Utc);
    let mut precision = TimeDelta::seconds(1);
    if let Some(subsec) = exif_ascii(&exif, exif::Tag::SubSecTimeOriginal)? {
        let subsec = subsec.trim_end_matches(' ');
        if subsec.is_empty() || subsec.len() > 9 || !subsec.bytes().all(|c| c.is_ascii_digit()) {
            return Err(eyre!("invalid EXIF capture subseconds"));
        }
        let scale = 10_i64.pow(9 - subsec.len() as u32);
        start += TimeDelta::nanoseconds(subsec.parse::<i64>()? * scale);
        precision = TimeDelta::nanoseconds(scale);
    }
    Ok(PhotoCaptureTime { start, precision })
}

fn exif_ascii(exif: &exif::Exif, tag: exif::Tag) -> Result<Option<&str>> {
    match exif.get_field(tag, exif::In::PRIMARY) {
        None => Ok(None),
        Some(exif::Field {
            value: exif::Value::Ascii(values),
            ..
        }) if values.len() == 1 => Ok(Some(std::str::from_utf8(&values[0])?)),
        Some(_) => Err(eyre!("invalid EXIF {tag}")),
    }
}

fn downloaded_photos(downloads_dir: &Utf8Path) -> Result<Vec<std::path::PathBuf>> {
    fn collect(directory: &std::path::Path, photos: &mut Vec<std::path::PathBuf>) -> Result<()> {
        for entry in std::fs::read_dir(directory)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                if !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(INCOMPLETE_DOWNLOADS_PREFIX)
                {
                    collect(&entry.path(), photos)?;
                }
            } else if file_type.is_file() && is_jpeg_path(&entry.path()) {
                photos.push(entry.path());
            }
        }
        Ok(())
    }
    let mut paths = Vec::new();
    collect(downloads_dir.as_std_path(), &mut paths)?;
    paths.sort();
    Ok(paths)
}

fn is_jpeg_path(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg")
        })
}

fn camera_downloads_dir(infractions_dir: &Utf8Path) -> Utf8PathBuf {
    infractions_dir.join(CAMERA_DOWNLOADS_DIR)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    const TEST_JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0x00];

    #[tokio::test]
    async fn uploads_pending_photo_and_metadata() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                let count = socket.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&request[..end]).to_lowercase();
                    let length: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            socket
                .write_all(
                    b"HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
                )
                .await
                .unwrap();
            request
        });
        let temp_dir = tempfile::tempdir().unwrap();
        let dir = Utf8PathBuf::from_path_buf(temp_dir.path().to_path_buf()).unwrap();
        let infraction = Infraction {
            recorded_speed: 42,
            authorized_speed: 30,
            location: "Lorgues".to_string(),
            datetime_taken: Utc::now(),
        };
        infraction.save_infraction_json(&dir).unwrap();
        let photo_path = infraction.photo_path(&dir);
        std::fs::write(&photo_path, TEST_JPEG).unwrap();
        let json_path = photo_path.with_extension("json");
        let uploader = InfractionUploaderInner::new(
            dir,
            format!("http://{address}"),
            "test-key".to_string(),
            false,
        );
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            uploader.upload_one(json_path.as_std_path()),
        )
        .await
        .unwrap()
        .unwrap();
        let request = server.await.unwrap();
        let request = String::from_utf8_lossy(&request);
        assert!(request.contains("x-api-key: test-key"));
        assert!(request.contains("name=\"photo\""));
        assert!(request.contains("name=\"infraction\""));
        assert!(request.contains("\"recorded_speed\":42"));
        assert!(!json_path.exists());
        assert!(photo_path.exists());
    }

    fn capture(dir: &Utf8Path, timestamp: &str) -> Infraction {
        let infraction = Infraction {
            recorded_speed: 42,
            authorized_speed: 30,
            location: "Test".into(),
            datetime_taken: DateTime::parse_from_rfc3339(timestamp)
                .unwrap()
                .with_timezone(&Utc),
        };
        infraction.save_infraction_json(dir).unwrap();
        infraction
    }

    fn jpeg(
        date: Option<&str>,
        subsec: Option<&str>,
        offset: Option<&str>,
        little_endian: bool,
    ) -> Vec<u8> {
        let mut fields = vec![exif::Field {
            tag: exif::Tag::Make,
            ifd_num: exif::In::PRIMARY,
            value: exif::Value::Ascii(vec![b"Test camera".to_vec()]),
        }];
        for (tag, value) in [
            (exif::Tag::DateTimeOriginal, date),
            (exif::Tag::SubSecTimeOriginal, subsec),
            (exif::Tag::OffsetTimeOriginal, offset),
        ] {
            if let Some(value) = value {
                fields.push(exif::Field {
                    tag,
                    ifd_num: exif::In::PRIMARY,
                    value: exif::Value::Ascii(vec![value.as_bytes().to_vec()]),
                });
            }
        }
        let mut writer = exif::experimental::Writer::new();
        for field in &fields {
            writer.push_field(field);
        }
        let mut tiff = std::io::Cursor::new(Vec::new());
        writer.write(&mut tiff, little_endian).unwrap();
        let mut result = vec![0xff, 0xd8, 0xff, 0xe1];
        result.extend_from_slice(&((tiff.get_ref().len() + 8) as u16).to_be_bytes());
        result.extend_from_slice(b"Exif\0\0");
        result.extend_from_slice(tiff.get_ref());
        result.extend_from_slice(&include_bytes!("test-photo.jpg")[2..]);
        result
    }

    fn camera_dirs() -> (tempfile::TempDir, Utf8PathBuf, Utf8PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let dir = Utf8PathBuf::from_path_buf(temp.path().to_path_buf()).unwrap();
        let downloads = camera_downloads_dir(&dir);
        std::fs::create_dir(&downloads).unwrap();
        (temp, dir, downloads)
    }

    fn match_photos(dir: &Utf8Path, downloads: &Utf8Path) -> Result<usize> {
        let now = DateTime::parse_from_rfc3339("2026-09-08T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        attach_downloaded_photos_at(dir, downloads, now)
    }

    #[test]
    fn matches_capture_time_despite_missing_shots_and_unrelated_photos() {
        let (_temp, dir, downloads) = camera_dirs();
        let missing = capture(&dir, "2026-09-07T12:00:00.100Z");
        let successful = capture(&dir, "2026-09-07T12:00:05.100Z");
        std::fs::write(
            downloads.join("DSC_0001.JPG"),
            jpeg(Some("2026:09:07 11:00:00"), None, None, false),
        )
        .unwrap();
        std::fs::write(
            downloads.join("DSC_0002.JPG"),
            jpeg(Some("2026:09:07 12:00:05"), None, None, true),
        )
        .unwrap();
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 1);
        assert!(!missing.photo_path(&dir).exists());
        assert!(successful.photo_path(&dir).exists());
        assert!(downloads.join("DSC_0001.JPG").exists());
    }

    #[test]
    fn ambiguous_capture_stays_unmatched_even_after_another_upload() {
        let (_temp, dir, downloads) = camera_dirs();
        let first = capture(&dir, "2026-09-07T12:00:00.100Z");
        let second = capture(&dir, "2026-09-07T12:00:00.800Z");
        let photo = downloads.join("DSC_0001.JPG");
        std::fs::write(&photo, jpeg(Some("2026:09:07 12:00:00"), None, None, true)).unwrap();
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 0);
        std::fs::rename(
            first.infraction_path(&dir),
            first.infraction_path(&dir).with_extension("uploaded"),
        )
        .unwrap();
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 0);
        assert!(!second.photo_path(&dir).exists());
        assert!(photo.exists());
    }

    #[test]
    fn matching_waits_for_later_triggers_in_the_same_timestamp_window() {
        let (_temp, dir, downloads) = camera_dirs();
        capture(&dir, "2026-09-07T12:00:00.100Z");
        let photo = downloads.join("photo.jpg");
        std::fs::write(&photo, jpeg(Some("2026:09:07 12:00:00"), None, None, true)).unwrap();
        let now = DateTime::parse_from_rfc3339("2026-09-07T12:00:00.200Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(
            attach_downloaded_photos_at(&dir, &downloads, now).unwrap(),
            0
        );
        capture(&dir, "2026-09-07T12:00:00.800Z");
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 0);
        assert!(photo.exists());
    }

    #[test]
    fn two_photos_competing_for_one_capture_are_not_guessed() {
        let (_temp, dir, downloads) = camera_dirs();
        let infraction = capture(&dir, "2026-09-07T12:00:00.100Z");
        for (name, little_endian) in [("DSC_0001.JPG", true), ("DSC_0002.JPG", false)] {
            std::fs::write(
                downloads.join(name),
                jpeg(Some("2026:09:07 12:00:00"), None, None, little_endian),
            )
            .unwrap();
        }
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 0);
        assert!(!infraction.photo_path(&dir).exists());
    }

    #[test]
    fn preserves_missing_malformed_and_incomplete_camera_timestamps() {
        let (_temp, dir, downloads) = camera_dirs();
        capture(&dir, "2026-09-07T12:00:00.100Z");
        let mut incomplete = jpeg(Some("2026:09:07 12:00:00"), None, None, true);
        incomplete.truncate(incomplete.len() - 2);
        for (name, data) in [
            ("missing.jpg", jpeg(None, None, None, true)),
            (
                "invalid.jpg",
                jpeg(Some("2026:99:07 12:00:00"), None, None, true),
            ),
            ("incomplete.jpg", incomplete),
            (
                "drifted.jpg",
                jpeg(Some("2026:09:07 12:00:03"), None, None, true),
            ),
        ] {
            std::fs::write(downloads.join(name), data).unwrap();
        }
        assert_eq!(match_photos(&dir, &downloads).unwrap(), 0);
        assert_eq!(std::fs::read_dir(downloads).unwrap().count(), 4);
    }

    #[test]
    fn reads_exif_offsets_subseconds_and_both_byte_orders() {
        let (_temp, _dir, downloads) = camera_dirs();
        for little_endian in [false, true] {
            let photo = downloads.join("photo.jpg");
            std::fs::write(
                &photo,
                jpeg(
                    Some("2026:09:07 14:00:00"),
                    Some("1234"),
                    Some("+02:00"),
                    little_endian,
                ),
            )
            .unwrap();
            let time = photo_capture_time(photo.as_std_path()).unwrap();
            assert_eq!(time.start.to_rfc3339(), "2026-09-07T12:00:00.123400+00:00");
            assert_eq!(time.precision, TimeDelta::microseconds(100));
        }
    }

    #[test]
    fn malformed_capture_metadata_stops_matching_instead_of_excluding_a_candidate() {
        let (_temp, dir, downloads) = camera_dirs();
        let infraction = capture(&dir, "2026-09-07T12:00:00.100Z");
        std::fs::write(dir.join("broken.json"), "{").unwrap();
        std::fs::write(
            downloads.join("photo.jpg"),
            jpeg(Some("2026:09:07 12:00:00"), None, None, true),
        )
        .unwrap();
        assert!(match_photos(&dir, &downloads).is_err());
        assert!(!infraction.photo_path(&dir).exists());
    }

    fn mock_camera(remote: &std::path::Path, counter: &std::path::Path) -> tokio::process::Command {
        let mut command = tokio::process::Command::new("sh");
        command.args([
            "-c",
            r#"
            set -eu
            test "$#" -eq 4
            test "$1" = --get-all-files
            test "$2" = --skip-existing
            test "$3" = --filename
            test "$4" = './%F/%f.%C'
            for directory in "$CAMERA_SOURCE"/store_*/DCIM/*; do
                test -d "$directory" || continue
                relative="${directory#"$CAMERA_SOURCE"/}"
                mkdir -p "$relative"
                for source in "$directory"/*.JPG; do
                    test -f "$source" || continue
                    destination="$relative/$(basename "$source")"
                    if test ! -e "$destination"; then
                        cp "$source" "$destination"
                        printf 1 >> "$TRANSFER_COUNTER"
                    fi
                done
            done
        "#,
            "mock-gphoto2",
        ]);
        command
            .env("CAMERA_SOURCE", remote)
            .env("TRANSFER_COUNTER", counter);
        command
    }

    fn remote_photo(remote: &std::path::Path, folder: &str, time: DateTime<Utc>) -> Utf8PathBuf {
        let relative = Utf8PathBuf::from(format!("store_00010001/DCIM/{folder}/DSC_0001.JPG"));
        let path = remote.join(&relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            path,
            jpeg(
                Some(&time.format("%Y:%m:%d %H:%M:%S").to_string()),
                None,
                None,
                true,
            ),
        )
        .unwrap();
        relative
    }

    #[tokio::test]
    async fn persistent_camera_cache_skips_repeat_transfers_and_handles_folder_rollover() {
        use std::os::unix::fs::MetadataExt;
        let (_temp, dir, downloads) = camera_dirs();
        let remote = dir.join("remote-camera");
        let counter = dir.join("transfer-count");
        let first_time = Utc::now() - TimeDelta::seconds(30);
        let first = capture(&dir, &first_time.to_rfc3339());
        let first_path = remote_photo(remote.as_std_path(), "100D3200", first_time);
        assert_eq!(
            retrieve_camera_photos_with_command(
                &dir,
                &mut mock_camera(remote.as_std_path(), counter.as_std_path())
            )
            .await
            .unwrap(),
            1
        );
        assert!(downloads.join(&first_path).exists());
        assert_eq!(
            std::fs::metadata(downloads.join(&first_path))
                .unwrap()
                .ino(),
            std::fs::metadata(first.photo_path(&dir)).unwrap().ino()
        );
        std::fs::rename(
            first.infraction_path(&dir),
            first.infraction_path(&dir).with_extension("uploaded"),
        )
        .unwrap();
        assert_eq!(
            retrieve_camera_photos_with_command(
                &dir,
                &mut mock_camera(remote.as_std_path(), counter.as_std_path())
            )
            .await
            .unwrap(),
            0
        );
        assert_eq!(std::fs::read(&counter).unwrap().len(), 1);
        let second_time = first_time + TimeDelta::seconds(5);
        let second = capture(&dir, &second_time.to_rfc3339());
        let second_path = remote_photo(remote.as_std_path(), "101D3200", second_time);
        assert_eq!(
            retrieve_camera_photos_with_command(
                &dir,
                &mut mock_camera(remote.as_std_path(), counter.as_std_path())
            )
            .await
            .unwrap(),
            1
        );
        assert_eq!(std::fs::read(counter).unwrap().len(), 2);
        assert_eq!(downloaded_photos(&downloads).unwrap().len(), 2);
        assert!(downloads.join(second_path).exists());
        assert!(second.photo_path(&dir).exists());
    }

    #[tokio::test]
    async fn partial_camera_cache_file_is_preserved_and_downloaded_again() {
        let (_temp, dir, downloads) = camera_dirs();
        let remote = dir.join("remote-camera");
        let counter = dir.join("transfer-count");
        let time = Utc::now() - TimeDelta::seconds(30);
        let infraction = capture(&dir, &time.to_rfc3339());
        let relative = remote_photo(remote.as_std_path(), "100D3200", time);
        let partial = downloads.join(&relative);
        std::fs::create_dir_all(partial.parent().unwrap()).unwrap();
        std::fs::write(&partial, [0xff, 0xd8, 0xff]).unwrap();
        assert_eq!(
            retrieve_camera_photos_with_command(
                &dir,
                &mut mock_camera(remote.as_std_path(), counter.as_std_path())
            )
            .await
            .unwrap(),
            1
        );
        assert_eq!(std::fs::read(counter).unwrap().len(), 1);
        assert_eq!(downloaded_photos(&downloads).unwrap().len(), 1);
        assert!(infraction.photo_path(&dir).exists());
        let quarantines: Vec<_> = std::fs::read_dir(partial.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap())
            .filter(|entry| entry.file_type().unwrap().is_dir())
            .collect();
        assert_eq!(quarantines.len(), 1);
        assert_eq!(
            std::fs::read(quarantines[0].path().join("DSC_0001.JPG")).unwrap(),
            [0xff, 0xd8, 0xff]
        );
    }

    #[tokio::test]
    async fn legacy_flat_download_and_cached_copy_count_as_one_photo() {
        let (_temp, dir, downloads) = camera_dirs();
        let remote = dir.join("remote-camera");
        let counter = dir.join("transfer-count");
        let time = Utc::now() - TimeDelta::seconds(30);
        let infraction = capture(&dir, &time.to_rfc3339());
        let relative = remote_photo(remote.as_std_path(), "100D3200", time);
        let old_path = downloads.join("DSC_0001.JPG");
        std::fs::copy(remote.join(&relative), &old_path).unwrap();
        assert_eq!(
            retrieve_camera_photos_with_command(
                &dir,
                &mut mock_camera(remote.as_std_path(), counter.as_std_path())
            )
            .await
            .unwrap(),
            1
        );
        assert_eq!(downloaded_photos(&downloads).unwrap().len(), 2);
        assert!(infraction.photo_path(&dir).exists());
        assert!(old_path.exists());
        assert!(downloads.join(relative).exists());
    }

    #[tokio::test]
    async fn local_only_legacy_photo_still_matches_when_camera_download_fails() {
        let (_temp, dir, downloads) = camera_dirs();
        let time = Utc::now() - TimeDelta::seconds(30);
        let infraction = capture(&dir, &time.to_rfc3339());
        let path = downloads.join("DSC_0001.JPG");
        std::fs::write(
            &path,
            jpeg(
                Some(&time.format("%Y:%m:%d %H:%M:%S").to_string()),
                None,
                None,
                true,
            ),
        )
        .unwrap();
        assert_eq!(
            retrieve_camera_photos_with_command(&dir, &mut tokio::process::Command::new("false"))
                .await
                .unwrap(),
            1
        );
        assert!(path.exists());
        assert!(infraction.photo_path(&dir).exists());
    }

    #[tokio::test]
    async fn startup_uploads_pending_files_and_retry_reuses_capture_id() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        tokio::task::LocalSet::new().run_until(async {
            let (_temp, dir, _downloads) = camera_dirs();
            let infraction = capture(&dir, "2026-09-07T12:00:00.100Z");
            std::fs::write(infraction.photo_path(&dir), TEST_JPEG).unwrap();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let uploader = InfractionUploader::new_with_photo_retrieval(dir.clone(), format!("http://{}", listener.local_addr().unwrap()), "key".into(), false);
            let mut requests = Vec::new();
            for response in [
                b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".as_slice(),
                b"HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".as_slice(),
            ] {
                let (mut socket, _) = tokio::time::timeout(RETRY_INTERVAL + Duration::from_secs(2), listener.accept()).await.unwrap().unwrap();
                let mut request = vec![0; 4096];
                let count = socket.read(&mut request).await.unwrap();
                requests.push(String::from_utf8_lossy(&request[..count]).into_owned());
                socket.write_all(response).await.unwrap();
            }
            let json_path = infraction.infraction_path(&dir);
            tokio::time::timeout(Duration::from_secs(2), async {
                while json_path.exists() { tokio::task::yield_now().await; }
            }).await.unwrap();
            let expected = format!("x-capture-id: {}\r\n", json_path.file_stem().unwrap());
            assert!(requests.iter().all(|request| request.contains(&expected)));
            assert!(json_path.with_extension("uploaded").exists());
            uploader.port.send(InfractionUploaderCommand::Shutdown).unwrap();
            uploader.port.join().await;
        }).await;
    }

    #[tokio::test]
    async fn hung_camera_command_is_killed_and_later_command_can_run() {
        let mut stuck = tokio::process::Command::new("sleep");
        stuck.arg("30");
        let start = std::time::Instant::now();
        assert!(
            camera_command_output(&mut stuck, Duration::from_millis(20))
                .await
                .unwrap_err()
                .to_string()
                .contains("timed out")
        );
        assert!(start.elapsed() < Duration::from_secs(1));
        let output = camera_command_output(
            &mut tokio::process::Command::new("true"),
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert!(output.status.success());
    }

    #[tokio::test]
    async fn unresponsive_http_server_times_out_without_retiring_capture() {
        use tokio::io::AsyncReadExt;
        tokio::task::LocalSet::new()
            .run_until(async {
                let (_temp, dir, _downloads) = camera_dirs();
                let infraction = capture(&dir, "2026-09-07T12:00:00.100Z");
                std::fs::write(infraction.photo_path(&dir), TEST_JPEG).unwrap();
                let json_path = infraction.infraction_path(&dir);
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                let uploader = InfractionUploaderInner::new(
                    dir,
                    format!("http://{}", listener.local_addr().unwrap()),
                    "key".into(),
                    false,
                );
                let task_path = json_path.clone();
                let upload = tokio::task::spawn_local(async move {
                    uploader.upload_one(task_path.as_std_path()).await
                });
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buffer = [0; 4096];
                socket.read(&mut buffer).await.unwrap();
                tokio::time::pause();
                tokio::time::advance(UPLOAD_TIMEOUT + Duration::from_secs(1)).await;
                let error = upload.await.unwrap().unwrap_err();
                assert!(error.downcast_ref::<reqwest::Error>().unwrap().is_timeout());
                assert!(json_path.exists());
                assert!(!json_path.with_extension("uploaded").exists());
            })
            .await;
    }
}
