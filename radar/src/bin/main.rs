#![no_std]
#![no_main]
#![deny(
    clippy::mem_forget,
    reason = "mem::forget is generally not safe to do with esp_hal types, especially those \
    holding buffers for the duration of a data transfer."
)]

const EVENTS_PREFIX: &str = "EVENTS: ";
const TARGET_PREFIX: &str = "TARGET: ";

use bt_hci::controller::ExternalController;
use embassy_executor::Spawner;
use esp_backtrace as _;
use esp_hal::{
    clock::CpuClock,
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
        targets_list_header_position, TargetsList, TARGETS_LIST_HEADER_LENGTH, TARGETS_LIST_LENGTH,
    },
};

const READ_BUF_SIZE: usize = 64;
const STREAM_BUF_SIZE: usize = 128;

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

async fn write(tx: &mut UartTx<'static, Async>, bytes: &[u8]) {
    defmt::info!("TX: {:#X}", bytes);
    embedded_io_async::Write::write(tx, bytes).await.unwrap();
    embedded_io_async::Write::flush(tx).await.unwrap();
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

async fn wait_for_ack(rx: &mut UartRx<'static, Async>) {
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

    if result.is_err() {
        panic!("Timed out waiting for ACK.");
    }
}

#[embassy_executor::task]
async fn reader(mut rx: UartRx<'static, Async>) {
    let mut rbuf = [0u8; STREAM_BUF_SIZE];
    let mut chunk = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    loop {
        let result = embedded_io_async::Read::read(&mut rx, &mut chunk).await;
        match result {
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
                            defmt::debug!("Targets: {:#?}", targets);
                            for target in targets.targets().iter().flatten() {
                                let speed = -target.speed;
                                defmt::info!(
                                    "{}{}{} {} {}",
                                    EVENTS_PREFIX,
                                    TARGET_PREFIX,
                                    speed,
                                    target.x,
                                    target.y
                                );
                            }
                        }
                        Err(err) => defmt::error!("Error parsing targets: {:?}", err),
                    }

                    rbuf.copy_within(TARGETS_LIST_LENGTH..offset, 0);
                    offset -= TARGETS_LIST_LENGTH;
                }
            }
            Err(err) => defmt::error!("RX Error: {:?}", err),
        }
    }
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

    let rng = esp_hal::rng::Rng::new(peripherals.RNG);
    let timer1 = TimerGroup::new(peripherals.TIMG0);
    let wifi_init = esp_wifi::init(timer1.timer0, rng, peripherals.RADIO_CLK)
        .expect("Failed to initialize WIFI/BLE controller");
    let (mut _wifi_controller, _interfaces) = esp_wifi::wifi::new(&wifi_init, peripherals.WIFI)
        .expect("Failed to initialize WIFI controller");
    // find more examples https://github.com/embassy-rs/trouble/tree/main/examples/esp32
    let transport = BleConnector::new(&wifi_init, peripherals.BT);
    let _ble_controller = ExternalController::<_, 20>::new(transport);

    let config = Config::default()
        // The docs say 115200 but the actual baud rate is 256000!!!
        .with_baudrate(256_000)
        .with_data_bits(DataBits::_8)
        .with_parity(Parity::None)
        .with_stop_bits(StopBits::_1);

    let uart1 = Uart::new(peripherals.UART1, config)
        .unwrap()
        .with_tx(peripherals.GPIO17)
        .with_rx(peripherals.GPIO18)
        .into_async();
    let (mut rx, mut tx) = uart1.split();
    defmt::info!("UART initialized");

    // Set detection mode
    flush_rx(&mut rx).await;
    write(&mut tx, OPEN_COMMAND_MODE.get()).await;
    wait_for_ack(&mut rx).await;
    write(&mut tx, SET_SINGLE_TARGET.get()).await;
    wait_for_ack(&mut rx).await;
    write(&mut tx, CLOSE_COMMAND_MODE.get()).await;
    wait_for_ack(&mut rx).await;
    flush_rx(&mut rx).await;
    defmt::info!("Entered single target mode");

    spawner.spawn(reader(rx)).ok();
}
