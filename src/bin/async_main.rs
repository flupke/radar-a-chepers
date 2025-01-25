#![no_std]
#![no_main]

use core::f32::consts::PI;

use embassy_executor::Spawner;
use embassy_sync::{blocking_mutex::raw::NoopRawMutex, signal::Signal};
use embedded_io_async::Write;
use esp_backtrace as _;
use esp_hal::{
    timer::timg::TimerGroup,
    uart::{Config, DataBits, Parity, StopBits, Uart, UartRx},
    Async,
};
use libm::{atan2f, sqrtf};
use static_cell::StaticCell;

// rx_fifo_full_threshold
const READ_BUF_SIZE: usize = 64;

#[derive(Debug)]
#[allow(dead_code)]
struct Human {
    x: i16,
    y: i16,
    speed: i16,
    distance_resolution: u16,
    distance: f32,
    angle: f32,
}

impl Human {
    fn new(buf: &[u8]) -> Self {
        let x = (buf[4] as u16 | ((buf[5] as u16) << 8)) as i16 - 0x200;
        let y = (buf[6] as u16 | ((buf[7] as u16) << 8)) as i16 - 0x4000;
        let x_f = x as f32;
        let y_f = y as f32;
        let speed = (buf[8] as i16 | ((buf[9] as i16) << 8)) - 0x10;
        let distance_resolution: u16 = buf[10] as u16 | ((buf[11] as u16) << 8);
        let distance = sqrtf(x_f * x_f + y_f * y_f);
        let angle = atan2f(y_f, x_f) * 180.0 / PI;
        Self {
            x,
            y,
            speed,
            distance,
            distance_resolution,
            angle,
        }
    }
}

#[embassy_executor::task]
async fn reader(mut rx: UartRx<'static, Async>, signal: &'static Signal<NoopRawMutex, usize>) {
    const MAX_BUFFER_SIZE: usize = 10 * READ_BUF_SIZE + 16;

    let mut rbuf: [u8; MAX_BUFFER_SIZE] = [0u8; MAX_BUFFER_SIZE];
    let mut offset = 0;
    loop {
        let r = embedded_io_async::Read::read(&mut rx, &mut rbuf[offset..]).await;
        if let Ok(len) = r {
            offset += len;
            if len == 30
                && rbuf[0] == 0xAA
                && rbuf[1] == 0xFF
                && rbuf[28] == 0x55
                && rbuf[29] == 0xCC
            {
                let cheper1 = Human::new(&rbuf[..offset]);
                esp_println::println!("Cheper 1: {cheper1:?}");
            }
            offset = 0;
            signal.signal(len);
        }
    }
}

#[esp_hal_embassy::main]
async fn main(spawner: Spawner) {
    esp_println::println!("Init!");
    let peripherals = esp_hal::init(esp_hal::Config::default());

    let timg0 = TimerGroup::new(peripherals.TIMG0);
    esp_hal_embassy::init(timg0.timer0);

    // Default pins for Uart/Serial communication
    let (tx_pin, rx_pin) = (peripherals.GPIO17, peripherals.GPIO16);

    let config = Config::default()
        .with_baudrate(256000)
        .with_data_bits(DataBits::_8)
        .with_parity(Parity::None)
        .with_stop_bits(StopBits::_1)
        .with_rx_fifo_full_threshold(READ_BUF_SIZE as u16);

    let uart2 = Uart::new(peripherals.UART2, config)
        .unwrap()
        .with_tx(tx_pin)
        .with_rx(rx_pin)
        .into_async();

    let (rx, mut tx) = uart2.split();

    static SIGNAL: StaticCell<Signal<NoopRawMutex, usize>> = StaticCell::new();
    let signal = &*SIGNAL.init(Signal::new());

    let data = [
        0xFD, 0xFC, 0xFB, 0xFA, 0x02, 0x00, 0x80, 0x00, 0x04, 0x03, 0x02, 0x01,
    ];
    tx.write(&data).await.unwrap();

    spawner.spawn(reader(rx, signal)).ok();
}
