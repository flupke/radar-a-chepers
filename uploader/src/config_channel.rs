use std::sync::Arc;
use std::time::Duration;

use phoenix_channels_client::{Client, Config, Payload};
use serde_json::Value;
use tokio::sync::broadcast;
use tokio::time::{self, Instant};

use crate::{
    infraction_recorder::{RadarConfig, TargetData},
    uploader_logger::UploaderLog,
};

pub async fn run(
    api_endpoint: String,
    api_key: String,
    config_tx: tokio::sync::mpsc::UnboundedSender<RadarConfig>,
    mut target_data_rx: broadcast::Receiver<TargetData>,
    mut uploader_log_rx: broadcast::Receiver<UploaderLog>,
) {
    loop {
        match connect_and_run(
            &api_endpoint,
            &api_key,
            &config_tx,
            &mut target_data_rx,
            &mut uploader_log_rx,
        )
        .await
        {
            Ok(()) => log::info!("Config channel closed, reconnecting..."),
            Err(e) => log::error!("Config channel error: {e}, reconnecting..."),
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn connect_and_run(
    api_endpoint: &str,
    api_key: &str,
    config_tx: &tokio::sync::mpsc::UnboundedSender<RadarConfig>,
    target_data_rx: &mut broadcast::Receiver<TargetData>,
    uploader_log_rx: &mut broadcast::Receiver<UploaderLog>,
) -> eyre::Result<()> {
    let ws_endpoint = api_endpoint
        .replace("https://", "wss://")
        .replace("http://", "ws://");
    let ws_url = format!("{ws_endpoint}/socket/websocket");

    let mut config = Config::new(ws_url.as_str()).map_err(|e| eyre::eyre!("invalid url: {e}"))?;
    config.set("api_key", api_key);

    log::info!("Connecting to config channel at {ws_url}...");
    let mut client = Client::new(config).map_err(|e| eyre::eyre!("client error: {e}"))?;
    client
        .connect()
        .await
        .map_err(|e| eyre::eyre!("connect error: {e}"))?;

    let channel = client
        .join("radar:config", Some(Duration::from_secs(10)))
        .await
        .map_err(|e| eyre::eyre!("join error: {e}"))?;
    log::info!("Joined radar:config channel");

    // Request initial config
    let reply = channel
        .send("get_config", serde_json::json!({}))
        .await
        .map_err(|e| eyre::eyre!("get_config error: {e}"))?;
    if let Some(config) = parse_config_payload(&reply) {
        let _ = config_tx.send(config);
        log::info!("Received initial config");
    }

    // Register handler for config_updated events
    let tx = config_tx.clone();
    channel
        .on(
            "config_updated",
            move |_channel: Arc<_>, payload: &Payload| {
                if let Some(config) = parse_config_payload(payload) {
                    let _ = tx.send(config);
                }
            },
        )
        .await
        .map_err(|e| eyre::eyre!("on error: {e}"))?;

    let ping_interval = Duration::from_secs(15);
    let mut ping = time::interval_at(Instant::now() + ping_interval, ping_interval);
    ping.set_missed_tick_behavior(time::MissedTickBehavior::Skip);

    let target_flush_interval = Duration::from_millis(100);
    let mut target_flush = time::interval_at(
        Instant::now() + target_flush_interval,
        target_flush_interval,
    );
    target_flush.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
    let mut latest_target_data = None;

    loop {
        tokio::select! {
            _ = ping.tick() => {
                if let Err(e) = channel
                    .send_with_timeout(
                        "ping",
                        serde_json::json!({}),
                        Some(Duration::from_secs(5)),
                    )
                    .await
                {
                    log::error!("Config channel ping failed: {e}, reconnecting...");
                    break;
                }
            },
            _ = target_flush.tick() => {
                if let Some(data) = latest_target_data.take() {
                    let payload = target_data_payload(&data);
                    if let Err(e) = channel.send_noreply("target_data", payload).await {
                        log::error!("Failed to send target data: {e}");
                        break;
                    }
                }
            },
            target_data = target_data_rx.recv() => {
                match target_data {
                    Ok(data) => {
                        if data.triggered {
                            latest_target_data = None;
                            let payload = target_data_payload(&data);
                            if let Err(e) = channel.send_noreply("target_data", payload).await {
                                log::error!("Failed to send target data: {e}");
                                break;
                            }
                        } else {
                            latest_target_data = Some(data);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            },
            uploader_log = uploader_log_rx.recv() => {
                match uploader_log {
                    Ok(log) => {
                        let payload = serde_json::json!({
                            "level": log.level,
                            "message": log.message,
                        });
                        if let Err(e) = channel.send_noreply("uploader_log", payload).await {
                            log::error!("Failed to send uploader log: {e}");
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            },
        }
    }

    Ok(())
}

fn target_data_payload(data: &TargetData) -> Value {
    serde_json::json!({
        "raw_speed_cm_s": data.raw_speed_cm_s,
        "speed": data.speed,
        "x": data.x,
        "y": data.y,
        "distance": data.distance,
        "angle": data.angle,
        "in_range": data.in_range,
        "in_aperture": data.in_aperture,
        "over_speed": data.over_speed,
        "cooldown_elapsed": data.cooldown_elapsed,
        "capture_paused": data.capture_paused,
        "capture_in_progress": data.capture_in_progress,
        "would_trigger": data.would_trigger,
        "triggered": data.triggered,
    })
}

fn parse_config_payload(payload: &Payload) -> Option<RadarConfig> {
    let value = match payload {
        Payload::Value(v) => v,
        Payload::Binary(_) => return None,
    };

    let authorized_speed = value.get("authorized_speed")?.as_i64()? as i16;
    let min_dist = value.get("min_dist")?.as_f64()?;
    let max_dist = value.get("max_dist")?.as_f64()?;
    let trigger_cooldown = value.get("trigger_cooldown")?.as_i64()?;
    let aperture_angle = value.get("aperture_angle")?.as_i64()? as i16;
    let capture_paused = value
        .get("capture_paused")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);

    Some(RadarConfig {
        authorized_speed,
        min_dist,
        max_dist,
        trigger_cooldown,
        aperture_angle,
        capture_paused,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(overrides: serde_json::Value) -> Payload {
        let mut value = serde_json::json!({
            "authorized_speed": 55,
            "min_dist": 1000.0,
            "max_dist": 12000.0,
            "trigger_cooldown": 2500,
            "aperture_angle": 75
        });

        let map = value.as_object_mut().unwrap();
        for (key, val) in overrides.as_object().unwrap() {
            map.insert(key.clone(), val.clone());
        }

        Payload::Value(value)
    }

    #[test]
    fn parses_capture_paused_signal_from_config_payload() {
        let config =
            parse_config_payload(&payload(serde_json::json!({"capture_paused": true}))).unwrap();

        assert!(config.capture_paused);
    }

    #[test]
    fn defaults_capture_paused_to_false_for_old_payloads() {
        let config = parse_config_payload(&payload(serde_json::json!({}))).unwrap();

        assert!(!config.capture_paused);
    }
}
