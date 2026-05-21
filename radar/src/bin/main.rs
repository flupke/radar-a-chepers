#![no_std]
#![no_main]
#![deny(
    clippy::mem_forget,
    reason = "mem::forget is generally not safe to do with esp_hal types, especially those \
    holding buffers for the duration of a data transfer."
)]

const EVENTS_PREFIX: &str = "EVENTS: ";
const TARGET_PREFIX: &str = "TARGET: ";
const TRIGGER_PREFIX: &str = "TRIGGER: ";
const TRIGGER_PULSE_MS: u64 = 150;
const CAPTURE_CHECK_LOG_INTERVAL: Duration = Duration::from_secs(1);

use bt_hci::controller::ExternalController;
use embassy_executor::Spawner;
use embassy_sync::{blocking_mutex::raw::NoopRawMutex, mutex::Mutex};
use embassy_time::{with_timeout, Duration, Instant, Timer};
use esp_backtrace as _;
use esp_hal::{
    clock::CpuClock,
    gpio::{Level, Output, OutputConfig},
    timer::{systimer::SystemTimer, timg::TimerGroup},
    uart::{Config, DataBits, Parity, StopBits, Uart, UartRx, UartTx},
    Async,
};
use esp_println as _;
use esp_wifi::ble::controller::BleConnector;
use radar_a_chepers::{
    command::{
        CLOSE_COMMAND_MODE, FRAME_FOOTER, FRAME_HEADER, OPEN_COMMAND_MODE, RESPONSE_FRAME_HEADER,
        SET_SINGLE_TARGET,
    },
    target::{
        targets_list_header_position, Target, TargetsList, TARGETS_LIST_HEADER_LENGTH,
        TARGETS_LIST_LENGTH,
    },
};
use static_cell::StaticCell;

#[derive(Clone, Copy)]
struct TriggerConfig {
    authorized_speed_kmh: i16,
    min_dist_mm: i32,
    max_dist_mm: i32,
    trigger_cooldown_ms: u64,
    aperture_angle_degrees: i16,
    capture_paused: bool,
}

impl TriggerConfig {
    const fn default() -> Self {
        Self {
            authorized_speed_kmh: 25,
            min_dist_mm: 0,
            max_dist_mm: 10_000,
            trigger_cooldown_ms: 1000,
            aperture_angle_degrees: 90,
            capture_paused: false,
        }
    }
}

type SharedTriggerConfig = Mutex<NoopRawMutex, TriggerConfig>;
static TRIGGER_CONFIG: StaticCell<SharedTriggerConfig> = StaticCell::new();

#[derive(Clone, Copy, PartialEq, Eq)]
enum TriggerDecision {
    Trigger,
    Paused,
    TooSlow,
    OutOfRange,
    OutOfAperture,
    Cooldown,
}

struct TriggerCheck {
    decision: TriggerDecision,
    speed_kmh: i16,
    authorized_speed_kmh: i16,
    suspicious_speed: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RawFrameState {
    Empty,
    Targets,
    SuspiciousSpeed,
}

impl RawFrameState {
    fn label(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::Targets => "targets",
            Self::SuspiciousSpeed => "suspicious-speed",
        }
    }
}

struct RawFrameDiagnostics {
    last_state: Option<RawFrameState>,
    saw_targets: bool,
}

impl RawFrameDiagnostics {
    fn new() -> Self {
        Self {
            last_state: None,
            saw_targets: false,
        }
    }

    fn observe(&mut self, targets: &TargetsList, frame: &[u8]) {
        let state = raw_frame_state(targets);
        let should_log = self.should_log(state);

        if state != RawFrameState::Empty {
            self.saw_targets = true;
        }

        if should_log {
            log_raw_frame_diagnostic(state, targets, frame);
        }

        self.last_state = Some(state);
    }

    fn should_log(&self, state: RawFrameState) -> bool {
        if self.last_state.is_none() {
            return true;
        }

        if state == RawFrameState::Empty && !self.saw_targets {
            return false;
        }

        self.last_state != Some(state)
    }
}

const READ_BUF_SIZE: usize = 64;
const STREAM_BUF_SIZE: usize = 128;
const CONFIG_UART_BAUDRATE: u32 = 115_200;
const RADAR_INIT_RETRY_DELAY: embassy_time::Duration = embassy_time::Duration::from_secs(2);
const RADAR_PASSIVE_PROBE_DURATION: embassy_time::Duration = embassy_time::Duration::from_secs(2);

esp_bootloader_esp_idf::esp_app_desc!();

fn command_response_header_position(buffer: &[u8]) -> Option<(usize, usize)> {
    let command_header = buffer
        .windows(FRAME_HEADER.len())
        .position(|window| window == FRAME_HEADER)
        .map(|position| (position, FRAME_HEADER.len()));
    let alternate_header = buffer
        .windows(RESPONSE_FRAME_HEADER.len())
        .position(|window| window == RESPONSE_FRAME_HEADER)
        .map(|position| (position, RESPONSE_FRAME_HEADER.len()));

    match (command_header, alternate_header) {
        (Some(command_header), Some(alternate_header)) => {
            Some(if command_header.0 <= alternate_header.0 {
                command_header
            } else {
                alternate_header
            })
        }
        (Some(command_header), None) => Some(command_header),
        (None, Some(alternate_header)) => Some(alternate_header),
        (None, None) => None,
    }
}

async fn write(tx: &mut UartTx<'static, Async>, bytes: &[u8]) -> Result<(), ()> {
    defmt::info!("TX: {:#X}", bytes);
    embedded_io_async::Write::write(tx, bytes)
        .await
        .map_err(|err| {
            defmt::warn!("UART write failed: {:?}", err);
        })?;
    embedded_io_async::Write::flush(tx).await.map_err(|err| {
        defmt::warn!("UART flush failed: {:?}", err);
    })?;
    Ok(())
}

/// Actively reads from the UART until it's empty to clear out old or junk data.
async fn flush_rx(rx: &mut UartRx<'static, Async>) {
    let mut buf = [0u8; READ_BUF_SIZE];
    embassy_time::with_timeout(embassy_time::Duration::from_millis(200), async {
        loop {
            embedded_io_async::Read::read(rx, &mut buf).await.ok();
        }
    })
    .await
    .ok();
}

async fn probe_radar_rx(rx: &mut UartRx<'static, Async>) -> bool {
    let mut chunk = [0u8; READ_BUF_SIZE];
    let mut byte_count = 0usize;
    let mut target_header_seen = false;
    let mut previous = [0u8; TARGETS_LIST_HEADER_LENGTH - 1];
    let mut previous_len = 0usize;

    let _ = embassy_time::with_timeout(RADAR_PASSIVE_PROBE_DURATION, async {
        loop {
            match embedded_io_async::Read::read(rx, &mut chunk).await {
                Ok(len) => {
                    if len == 0 {
                        continue;
                    }

                    defmt::info!("Passive radar RX: {:#X}", &chunk[..len]);
                    byte_count += len;

                    let mut combined = [0u8; READ_BUF_SIZE + TARGETS_LIST_HEADER_LENGTH - 1];
                    combined[..previous_len].copy_from_slice(&previous[..previous_len]);
                    combined[previous_len..previous_len + len].copy_from_slice(&chunk[..len]);
                    if targets_list_header_position(&combined[..previous_len + len]).is_some() {
                        target_header_seen = true;
                    }

                    let keep = (previous_len + len).min(previous.len());
                    combined.copy_within(previous_len + len - keep..previous_len + len, 0);
                    previous[..keep].copy_from_slice(&combined[..keep]);
                    previous_len = keep;
                }
                Err(err) => {
                    defmt::warn!("Passive radar RX error: {:?}", err);
                }
            }
        }
    })
    .await;

    if byte_count == 0 {
        defmt::warn!(
            "No bytes received from radar module during {} ms passive probe",
            RADAR_PASSIVE_PROBE_DURATION.as_millis()
        );
    } else if target_header_seen {
        defmt::info!("Radar target frame header observed during passive probe");
    } else {
        defmt::warn!(
            "Received {} byte(s) from radar during passive probe, but no target frame header",
            byte_count
        );
    }

    target_header_seen
}

async fn wait_for_ack(rx: &mut UartRx<'static, Async>) -> Result<(), ()> {
    let mut buffer = [0u8; STREAM_BUF_SIZE];
    let mut chunk = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    let result = embassy_time::with_timeout(embassy_time::Duration::from_secs(10), async {
        'wait: loop {
            match embedded_io_async::Read::read(rx, &mut chunk).await {
                Ok(len) => {
                    if len == 0 {
                        continue;
                    }
                    if offset + len > buffer.len() {
                        defmt::warn!("ACK buffer full; discarding stale bytes.");
                        offset = 0;
                    }
                    buffer[offset..offset + len].copy_from_slice(&chunk[..len]);
                    offset += len;
                    defmt::info!("RX: {:#X}", &buffer[..offset]);

                    loop {
                        let header_len = match command_response_header_position(&buffer[..offset]) {
                            Some(header_offset) if header_offset.0 > 0 => {
                                buffer.copy_within(header_offset.0..offset, 0);
                                offset -= header_offset.0;
                                header_offset.1
                            }
                            Some(header_offset) => header_offset.1,
                            None => {
                                let keep = offset.min(RESPONSE_FRAME_HEADER.len() - 1);
                                buffer.copy_within(offset - keep..offset, 0);
                                offset = keep;
                                break;
                            }
                        };

                        if offset < header_len + 2 {
                            break;
                        }

                        let data_len =
                            u16::from_le_bytes([buffer[header_len], buffer[header_len + 1]])
                                as usize;
                        let frame_len = header_len + 2 + data_len + FRAME_FOOTER.len();
                        if frame_len > buffer.len() {
                            defmt::warn!("Invalid ACK length: {}", data_len);
                            buffer.copy_within(1..offset, 0);
                            offset -= 1;
                            continue;
                        }
                        if offset < frame_len {
                            break;
                        }
                        if buffer[frame_len - FRAME_FOOTER.len()..frame_len] == FRAME_FOOTER {
                            defmt::info!("ACK: {:#X}", &buffer[..frame_len]);
                            break 'wait;
                        }

                        defmt::warn!("Discarding malformed ACK frame.");
                        buffer.copy_within(1..offset, 0);
                        offset -= 1;
                    }
                }
                Err(error) => {
                    defmt::warn!("RX error while waiting ACK: {:?}", error);
                }
            }
        }
    })
    .await;

    match result {
        Ok(()) => Ok(()),
        Err(_) => {
            defmt::warn!("Timed out waiting for ACK.");
            Err(())
        }
    }
}

async fn send_command_and_wait_for_ack(
    tx: &mut UartTx<'static, Async>,
    rx: &mut UartRx<'static, Async>,
    command: &[u8],
) -> Result<(), ()> {
    write(tx, command).await?;
    wait_for_ack(rx).await
}

async fn configure_radar(tx: &mut UartTx<'static, Async>, rx: &mut UartRx<'static, Async>) {
    let mut attempt = 1;

    loop {
        defmt::info!("Configuring radar module, attempt {}", attempt);
        let target_stream_seen = probe_radar_rx(rx).await;

        let result = async {
            send_command_and_wait_for_ack(tx, rx, OPEN_COMMAND_MODE.get()).await?;
            send_command_and_wait_for_ack(tx, rx, SET_SINGLE_TARGET.get()).await?;
            send_command_and_wait_for_ack(tx, rx, CLOSE_COMMAND_MODE.get()).await?;
            Ok(())
        }
        .await;

        match result {
            Ok(()) => {
                flush_rx(rx).await;
                defmt::info!("Entered single target mode");
                return;
            }
            Err(()) => {
                if target_stream_seen {
                    defmt::warn!(
                        "Radar configuration was not acknowledged, but target stream is already present; continuing"
                    );
                    return;
                }

                defmt::warn!(
                    "Radar module did not acknowledge configuration attempt {}; retrying in {} ms",
                    attempt,
                    RADAR_INIT_RETRY_DELAY.as_millis()
                );
                attempt += 1;
                embassy_time::Timer::after(RADAR_INIT_RETRY_DELAY).await;
            }
        }
    }
}

async fn handle_host_config_bytes(
    bytes: &[u8],
    line_buf: &mut [u8; 128],
    line_len: &mut usize,
    trigger_config: &'static SharedTriggerConfig,
    tx: &mut UartTx<'static, Async>,
) {
    for byte in bytes {
        match *byte {
            b'\n' | b'\r' => {
                if *line_len > 0 {
                    let response =
                        if handle_host_command(&line_buf[..*line_len], trigger_config).await {
                            b"CONFIG_OK\n".as_slice()
                        } else {
                            b"CONFIG_ERR\n".as_slice()
                        };
                    write_config_response(tx, response).await;
                    *line_len = 0;
                }
            }
            byte if *line_len < line_buf.len() => {
                line_buf[*line_len] = byte;
                *line_len += 1;
            }
            _ => {
                defmt::warn!("Host command line too long; discarding.");
                *line_len = 0;
            }
        }
    }
}

#[embassy_executor::task]
async fn config_reader(
    mut rx: UartRx<'static, Async>,
    mut tx: UartTx<'static, Async>,
    trigger_config: &'static SharedTriggerConfig,
) {
    let mut read_buf = [0u8; READ_BUF_SIZE];
    let mut line_buf = [0u8; 128];
    let mut line_len = 0usize;
    defmt::info!(
        "Pi config UART initialized: baud={} rx=GPIO40 tx=GPIO41",
        CONFIG_UART_BAUDRATE
    );

    loop {
        match embedded_io_async::Read::read(&mut rx, &mut read_buf).await {
            Ok(len) => {
                if len == 0 {
                    Timer::after(Duration::from_millis(1)).await;
                    continue;
                }

                handle_host_config_bytes(
                    &read_buf[..len],
                    &mut line_buf,
                    &mut line_len,
                    trigger_config,
                    &mut tx,
                )
                .await;
            }
            Err(err) => {
                defmt::warn!("Config UART read failed: {:?}", err);
                Timer::after(Duration::from_millis(100)).await;
            }
        }
    }
}

async fn write_config_response(tx: &mut UartTx<'static, Async>, bytes: &[u8]) {
    if let Err(err) = embedded_io_async::Write::write(tx, bytes).await {
        defmt::warn!("Config UART response write failed: {:?}", err);
        return;
    }

    if let Err(err) = embedded_io_async::Write::flush(tx).await {
        defmt::warn!("Config UART response flush failed: {:?}", err);
    }
}

async fn handle_host_command(line: &[u8], trigger_config: &'static SharedTriggerConfig) -> bool {
    let Ok(line) = core::str::from_utf8(line) else {
        defmt::warn!("Ignoring non-UTF8 host command.");
        return false;
    };

    let Some(config) = parse_config_command(line) else {
        defmt::warn!("Ignoring unknown host command.");
        return false;
    };

    *trigger_config.lock().await = config;
    defmt::info!(
        "Trigger config updated: authorized_speed={}km/h, min_dist={}mm, max_dist={}mm, cooldown={}ms, aperture={}deg, paused={}",
        config.authorized_speed_kmh,
        config.min_dist_mm,
        config.max_dist_mm,
        config.trigger_cooldown_ms,
        config.aperture_angle_degrees,
        config.capture_paused
    );
    true
}

fn parse_config_command(line: &str) -> Option<TriggerConfig> {
    let mut parts = line.split_whitespace();
    if parts.next()? != "CONFIG" {
        return None;
    }

    Some(TriggerConfig {
        authorized_speed_kmh: parts.next()?.parse().ok()?,
        min_dist_mm: parts.next()?.parse().ok()?,
        max_dist_mm: parts.next()?.parse().ok()?,
        trigger_cooldown_ms: parts.next()?.parse().ok()?,
        aperture_angle_degrees: parts.next()?.parse().ok()?,
        capture_paused: match parts.next()? {
            "0" => false,
            "1" => true,
            _ => return None,
        },
    })
}

#[embassy_executor::task]
async fn reader(
    mut rx: UartRx<'static, Async>,
    mut trigger: Output<'static>,
    trigger_config: &'static SharedTriggerConfig,
) {
    let mut rbuf = [0u8; STREAM_BUF_SIZE];
    let mut chunk = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    let mut last_trigger_at: Option<Instant> = None;
    let mut last_check_log_at: Option<Instant> = None;
    let mut last_check_decision: Option<TriggerDecision> = None;
    let mut raw_frame_diagnostics = RawFrameDiagnostics::new();

    loop {
        let result = with_timeout(
            Duration::from_millis(20),
            embedded_io_async::Read::read(&mut rx, &mut chunk),
        )
        .await;
        match result {
            Err(_) => {}
            Ok(result) => match result {
                Ok(len) => {
                    if len == 0 {
                        continue;
                    }

                    if offset + len > rbuf.len() {
                        defmt::warn!("Target buffer full; discarding stale bytes.");
                        offset = 0;
                    }
                    rbuf[offset..offset + len].copy_from_slice(&chunk[..len]);
                    offset += len;
                    defmt::debug!("RX: {:#X}", &rbuf[..offset]);

                    loop {
                        match targets_list_header_position(&rbuf[..offset]) {
                            Some(header_offset) if header_offset > 0 => {
                                rbuf.copy_within(header_offset..offset, 0);
                                offset -= header_offset;
                            }
                            Some(_) => {}
                            None => {
                                let keep = offset.min(TARGETS_LIST_HEADER_LENGTH - 1);
                                rbuf.copy_within(offset - keep..offset, 0);
                                offset = keep;
                                break;
                            }
                        }

                        if offset < TARGETS_LIST_LENGTH {
                            break;
                        }

                        match TargetsList::try_from(&rbuf[..TARGETS_LIST_LENGTH]) {
                            Ok(targets) => {
                                raw_frame_diagnostics
                                    .observe(&targets, &rbuf[..TARGETS_LIST_LENGTH]);
                                defmt::debug!("Targets: {:#?}", targets);
                                for target in targets.targets().iter().flatten() {
                                    let speed = target.speed.saturating_neg();
                                    defmt::info!(
                                        "{}{}{} {} {}",
                                        EVENTS_PREFIX,
                                        TARGET_PREFIX,
                                        speed,
                                        target.x,
                                        target.y
                                    );

                                    let check =
                                        trigger_check(target, trigger_config, last_trigger_at)
                                            .await;
                                    if should_log_capture_check(
                                        check.decision,
                                        last_check_decision,
                                        last_check_log_at,
                                    ) {
                                        log_capture_check(&check, target);
                                        last_check_log_at = Some(Instant::now());
                                        last_check_decision = Some(check.decision);
                                    }

                                    if check.decision == TriggerDecision::Trigger {
                                        let now = Instant::now();
                                        last_trigger_at = Some(now);
                                        last_check_log_at = Some(now);
                                        last_check_decision = Some(check.decision);
                                        defmt::info!(
                                            "{}{}{} {} {}",
                                            EVENTS_PREFIX,
                                            TRIGGER_PREFIX,
                                            speed,
                                            target.x,
                                            target.y
                                        );
                                        pulse_trigger(&mut trigger).await;
                                    }
                                }
                            }
                            Err(err) => defmt::error!("Error parsing targets: {:?}", err),
                        }

                        rbuf.copy_within(TARGETS_LIST_LENGTH..offset, 0);
                        offset -= TARGETS_LIST_LENGTH;
                    }
                }
                Err(err) => defmt::error!("RX Error: {:?}", err),
            },
        }
    }
}

async fn trigger_check(
    target: &Target,
    trigger_config: &'static SharedTriggerConfig,
    last_trigger_at: Option<Instant>,
) -> TriggerCheck {
    let config = *trigger_config.lock().await;
    let raw_speed_kmh = raw_speed_cm_s_to_abs_kmh(target.speed);
    let suspicious_speed = is_suspicious_rd03d_speed(target.speed);
    let speed_kmh =
        effective_speed_kmh(raw_speed_kmh, config.authorized_speed_kmh, suspicious_speed);
    let mut check = TriggerCheck {
        decision: TriggerDecision::Trigger,
        speed_kmh,
        authorized_speed_kmh: config.authorized_speed_kmh,
        suspicious_speed,
    };

    if config.capture_paused {
        check.decision = TriggerDecision::Paused;
        return check;
    }

    if speed_kmh <= config.authorized_speed_kmh {
        check.decision = TriggerDecision::TooSlow;
        return check;
    }

    let distance_squared =
        i64::from(target.x) * i64::from(target.x) + i64::from(target.y) * i64::from(target.y);
    let min_squared = i64::from(config.min_dist_mm) * i64::from(config.min_dist_mm);
    let max_squared = i64::from(config.max_dist_mm) * i64::from(config.max_dist_mm);
    if distance_squared < min_squared || distance_squared > max_squared {
        check.decision = TriggerDecision::OutOfRange;
        return check;
    }

    let angle =
        libm::atan2f(target.x as f32, target.y as f32).abs() * 180.0 / core::f32::consts::PI;
    if angle > config.aperture_angle_degrees as f32 / 2.0 {
        check.decision = TriggerDecision::OutOfAperture;
        return check;
    }

    if let Some(last_trigger_at) = last_trigger_at {
        if last_trigger_at.elapsed() < Duration::from_millis(config.trigger_cooldown_ms) {
            check.decision = TriggerDecision::Cooldown;
        }
    }

    check
}

fn should_log_capture_check(
    decision: TriggerDecision,
    last_decision: Option<TriggerDecision>,
    last_log_at: Option<Instant>,
) -> bool {
    if last_decision != Some(decision) {
        return true;
    }

    match last_log_at {
        Some(last_log_at) => last_log_at.elapsed() >= CAPTURE_CHECK_LOG_INTERVAL,
        None => true,
    }
}

fn log_capture_check(check: &TriggerCheck, target: &Target) {
    match check.decision {
        TriggerDecision::Trigger => {
            defmt::info!(
                "Capture check passed: speed={}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
        TriggerDecision::Paused => {
            defmt::info!(
                "Capture check blocked: paused speed={}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
        TriggerDecision::TooSlow => {
            defmt::info!(
                "Capture check blocked: speed {}km/h <= limit {}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.authorized_speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
        TriggerDecision::OutOfRange => {
            defmt::info!(
                "Capture check blocked: out of range speed={}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
        TriggerDecision::OutOfAperture => {
            defmt::info!(
                "Capture check blocked: outside aperture speed={}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
        TriggerDecision::Cooldown => {
            defmt::info!(
                "Capture check blocked: cooldown speed={}km/h sentinel={} x={} y={}",
                check.speed_kmh,
                check.suspicious_speed,
                target.x,
                target.y
            );
        }
    }
}

fn raw_speed_cm_s_to_abs_kmh(raw_speed_cm_s: i16) -> i16 {
    ((i32::from(raw_speed_cm_s).abs() * 36 + 500) / 1000) as i16
}

fn effective_speed_kmh(
    raw_speed_kmh: i16,
    authorized_speed_kmh: i16,
    suspicious_speed: bool,
) -> i16 {
    if suspicious_speed {
        raw_speed_kmh.max(authorized_speed_kmh.saturating_add(1))
    } else {
        raw_speed_kmh
    }
}

fn raw_frame_state(targets: &TargetsList) -> RawFrameState {
    let mut has_targets = false;

    for target in targets.targets().iter().flatten() {
        has_targets = true;
        if is_suspicious_rd03d_speed(target.speed) {
            return RawFrameState::SuspiciousSpeed;
        }
    }

    if has_targets {
        RawFrameState::Targets
    } else {
        RawFrameState::Empty
    }
}

fn is_suspicious_rd03d_speed(raw_speed_cm_s: i16) -> bool {
    matches!(i32::from(raw_speed_cm_s).abs(), 248 | 256)
}

fn log_raw_frame_diagnostic(state: RawFrameState, targets: &TargetsList, frame: &[u8]) {
    defmt::info!(
        "Radar raw frame diagnostic: state={} targets={} bytes={:#X}",
        state.label(),
        target_count(targets),
        frame
    );

    for target in targets.targets().iter().flatten() {
        defmt::info!(
            "Radar raw target: speed={}cm/s x={} y={} res={}",
            target.speed.saturating_neg(),
            target.x,
            target.y,
            target.distance_resolution
        );
    }
}

fn target_count(targets: &TargetsList) -> usize {
    targets
        .targets()
        .iter()
        .filter(|target| target.is_some())
        .count()
}

async fn pulse_trigger(trigger: &mut Output<'static>) {
    trigger.set_high();
    Timer::after(Duration::from_millis(TRIGGER_PULSE_MS)).await;
    trigger.set_low();
}

#[esp_hal_embassy::main]
async fn main(spawner: Spawner) {
    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let peripherals = esp_hal::init(config);

    esp_alloc::heap_allocator!(size: 64 * 1024);
    // COEX needs more RAM - so we've added some more
    esp_alloc::heap_allocator!(#[unsafe(link_section = ".dram2_uninit")] size: 64 * 1024);

    let timer0 = SystemTimer::new(peripherals.SYSTIMER);
    esp_hal_embassy::init(timer0.alarm0);

    defmt::info!("Embassy initialized!");

    let trigger_config = TRIGGER_CONFIG.init(Mutex::new(TriggerConfig::default()));
    let trigger_output = Output::new(peripherals.GPIO42, Level::Low, OutputConfig::default());

    let rng = esp_hal::rng::Rng::new(peripherals.RNG);
    let timer1 = TimerGroup::new(peripherals.TIMG0);
    let wifi_init = esp_wifi::init(timer1.timer0, rng, peripherals.RADIO_CLK)
        .expect("Failed to initialize WIFI/BLE controller");
    let (mut _wifi_controller, _interfaces) = esp_wifi::wifi::new(&wifi_init, peripherals.WIFI)
        .expect("Failed to initialize WIFI controller");
    // find more examples https://github.com/embassy-rs/trouble/tree/main/examples/esp32
    let transport = BleConnector::new(&wifi_init, peripherals.BT);
    let _ble_controller = ExternalController::<_, 20>::new(transport);

    let radar_uart_config = Config::default()
        // The docs say 115200 but the actual baud rate is 256000!!!
        .with_baudrate(256_000)
        .with_data_bits(DataBits::_8)
        .with_parity(Parity::None)
        .with_stop_bits(StopBits::_1);

    let uart1 = Uart::new(peripherals.UART1, radar_uart_config)
        .unwrap()
        .with_tx(peripherals.GPIO17)
        .with_rx(peripherals.GPIO18)
        .into_async();
    let (mut rx, mut tx) = uart1.split();
    defmt::info!("Radar UART initialized");

    let config_uart_config = Config::default()
        .with_baudrate(CONFIG_UART_BAUDRATE)
        .with_data_bits(DataBits::_8)
        .with_parity(Parity::None)
        .with_stop_bits(StopBits::_1);

    let config_uart = Uart::new(peripherals.UART2, config_uart_config)
        .unwrap()
        .with_tx(peripherals.GPIO41)
        .with_rx(peripherals.GPIO40)
        .into_async();
    let (config_rx, config_tx) = config_uart.split();

    configure_radar(&mut tx, &mut rx).await;

    spawner
        .spawn(config_reader(config_rx, config_tx, trigger_config))
        .ok();
    spawner
        .spawn(reader(rx, trigger_output, trigger_config))
        .ok();
}
