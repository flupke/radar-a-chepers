#![no_std]
#![no_main]
#![deny(
    clippy::mem_forget,
    reason = "mem::forget is generally not safe to do with esp_hal types, especially those \
    holding buffers for the duration of a data transfer."
)]

const EVENTS_PREFIX: &str = "EVENTS: ";
const MAX_SPEED_PREFIX: &str = "MAX_SPEED: ";

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
    command::{FRAME_FOOTER, FRAME_HEADER, SET_SINGLE_TARGET},
    target::TargetsList,
};

const READ_BUF_SIZE: usize = 64;

esp_bootloader_esp_idf::esp_app_desc!();

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
    let mut buffer = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    let result = embassy_time::with_timeout(embassy_time::Duration::from_secs(10), async {
        loop {
            match embedded_io_async::Read::read(rx, &mut buffer[offset..]).await {
                Ok(len) => {
                    offset += len;
                    defmt::info!("RX: {:#X}", &buffer[..offset]);
                    if buffer[..offset].starts_with(&FRAME_HEADER)
                        && buffer[..offset].ends_with(&FRAME_FOOTER)
                    {
                        break;
                    }
                    if offset >= buffer.len() {
                        defmt::warn!("Buffer overflow waiting for ACK.");
                        offset = 0;
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
    let mut rbuf = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    loop {
        let result = embedded_io_async::Read::read(&mut rx, &mut rbuf[offset..]).await;
        match result {
            Ok(len) => {
                offset += len;
                defmt::debug!("RX: {:#X}", &rbuf[..offset]);
                match TargetsList::try_from(&rbuf[..offset]) {
                    Ok(targets) => {
                        defmt::debug!("Targets: {:#?}", targets);
                        let max_speed = targets.max_speed();
                        defmt::info!("{}{}{}", EVENTS_PREFIX, MAX_SPEED_PREFIX, max_speed);
                    }
                    Err(err) => {
                        defmt::error!("Error parsing targets: {:?}", err);
                    }
                }
                offset = 0;
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
    write(&mut tx, SET_SINGLE_TARGET.get()).await;
    wait_for_ack(&mut rx).await;
    flush_rx(&mut rx).await;
    defmt::info!("Entered single target mode");

    spawner.spawn(reader(rx)).ok();
}
