use std::sync::Arc;
use std::time::Duration;

use phoenix_channels_client::{Client, Config, Payload};
use tokio::sync::broadcast;

use crate::infraction_recorder::{RadarConfig, TargetData};

pub async fn run(
    api_endpoint: String,
    api_key: String,
    config_tx: tokio::sync::mpsc::UnboundedSender<RadarConfig>,
    mut target_data_rx: broadcast::Receiver<TargetData>,
) {
    loop {
        match connect_and_run(&api_endpoint, &api_key, &config_tx, &mut target_data_rx).await {
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
) -> eyre::Result<()> {
    let ws_endpoint = api_endpoint
        .replace("https://", "wss://")
        .replace("http://", "ws://");
    let ws_url = format!("{ws_endpoint}/socket/websocket");

    let mut config = Config::new(ws_url.as_str()).map_err(|e| eyre::eyre!("invalid url: {e}"))?;
    config.set("api_key", api_key);

    log::info!("Connecting to config channel at {ws_url}...");
    let mut client = Client::new(config).map_err(|e| eyre::eyre!("client error: {e}"))?;
    client.connect().await.map_err(|e| eyre::eyre!("connect error: {e}"))?;

    let channel = client
        .join("radar:config", Some(Duration::from_secs(10)))
        .await
        .map_err(|e| eyre::eyre!("join error: {e}"))?;
    log::info!("Joined radar:config channel");

    // Register handler for config_updated events
    let tx = config_tx.clone();
    channel
        .on("config_updated", move |_channel: Arc<_>, payload: &Payload| {
            if let Some(config) = parse_config_payload(payload) {
                let _ = tx.send(config);
            }
        })
        .await
        .map_err(|e| eyre::eyre!("on error: {e}"))?;

    // Throttle target data sending to ~5 Hz
    let mut last_target_send = tokio::time::Instant::now();
    let throttle_interval = Duration::from_millis(200);

    loop {
        match target_data_rx.recv().await {
            Ok(data) => {
                let now = tokio::time::Instant::now();
                if now.duration_since(last_target_send) >= throttle_interval {
                    let payload = serde_json::json!({
                        "speed": data.speed,
                        "x": data.x,
                        "y": data.y,
                        "distance": data.distance,
                        "triggered": data.triggered,
                    });
                    if let Err(e) = channel.send_noreply("target_data", payload).await {
                        log::error!("Failed to send target data: {e}");
                        break;
                    }
                    last_target_send = now;
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }

    Ok(())
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

    Some(RadarConfig {
        authorized_speed,
        min_dist,
        max_dist,
        trigger_cooldown,
    })
}
