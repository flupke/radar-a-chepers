use esp_idf_hal::delay::TickType;
use esp_idf_hal::delay::BLOCK;
use esp_idf_hal::gpio;
use esp_idf_hal::peripherals::Peripherals;
use esp_idf_hal::prelude::*;
use esp_idf_hal::sys::esp_timer_get_time;
use esp_idf_hal::uart::*;
use radar_a_chepers::command::FRAME_FOOTER;
use radar_a_chepers::command::FRAME_HEADER;
use radar_a_chepers::command::SET_SINGLE_TARGET;
use radar_a_chepers::target::TargetsList;

const READ_BUF_SIZE: usize = 64;

fn write(uart: &mut UartDriver<'_>, bytes: &[u8]) -> eyre::Result<()> {
    uart.write(bytes).unwrap();
    uart.wait_tx_done(TickType::new_millis(100).into())?;
    Ok(())
}

/// Actively reads from the UART until it's empty to clear out old or junk data.
fn flush_rx(uart: &mut UartDriver<'_>) {
    let mut buf = [0u8; READ_BUF_SIZE];
    let start_time = unsafe { esp_timer_get_time() };
    while unsafe { esp_timer_get_time() } - start_time < 100 * 1000 {
        uart.read(&mut buf, TickType::new_millis(100).into()).ok();
    }
}

fn wait_for_ack(uart: &mut UartDriver<'_>) -> eyre::Result<()> {
    let mut buffer = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    let start_time = unsafe { esp_timer_get_time() };
    const TIMEOUT_US: i64 = 2 * 1000 * 1000; // 2 seconds

    loop {
        // Check for the overall 2-second timeout.
        if unsafe { esp_timer_get_time() } - start_time > TIMEOUT_US {
            return Err(eyre::eyre!("Timed out waiting for ACK."));
        }

        let mut byte_buf = [0u8; 1];
        // Perform a single-byte read with a short timeout. This allows the loop
        // to remain responsive and check the main timeout.
        match uart.read(&mut byte_buf, TickType::new_millis(100).into()) {
            Ok(_) => {
                // A byte was received, so append it to our buffer.
                buffer[offset] = byte_buf[0];
                offset += 1;

                log::debug!("RX: {:#?}", &buffer[..offset]);

                // Check if the buffer contains the complete ACK frame.
                if buffer[..offset].starts_with(&FRAME_HEADER)
                    && buffer[..offset].ends_with(&FRAME_FOOTER)
                {
                    return Ok(());
                }

                // If the buffer is full and we haven't found an ACK, reset it.
                if offset >= buffer.len() {
                    log::warn!("Buffer overflow waiting for ACK.");
                    offset = 0;
                }
            }
            Err(_) => {
                // A read error likely means a timeout, which is expected.
                // Continue the loop to keep checking for data.
            }
        }
    }
}

fn main() -> eyre::Result<()> {
    esp_idf_hal::sys::link_patches();

    // Bind the log crate to the ESP Logging facilities
    esp_idf_svc::log::EspLogger::initialize_default();

    let peripherals = Peripherals::take()?;
    let tx = peripherals.pins.gpio17;
    let rx = peripherals.pins.gpio18;

    println!("Starting UART loopback test");
    let config = config::Config::new()
        .baudrate(Hertz(256_000))
        .data_bits(config::DataBits::DataBits8)
        .parity_none()
        .stop_bits(config::StopBits::STOP1);
    let mut uart = UartDriver::new(
        peripherals.uart1,
        tx,
        rx,
        Option::<gpio::Gpio0>::None,
        Option::<gpio::Gpio1>::None,
        &config,
    )?;

    // Set detection mode
    flush_rx(&mut uart);
    write(&mut uart, &SET_SINGLE_TARGET)?;
    wait_for_ack(&mut uart)?;
    flush_rx(&mut uart);
    log::info!("Entered single target mode");

    let mut rbuf = [0u8; READ_BUF_SIZE];
    let mut offset = 0;
    loop {
        let result = uart.read(&mut rbuf[offset..], BLOCK);
        match result {
            Ok(len) => {
                offset += len;
                log::debug!("RX: {:?}", &rbuf[..offset]);
                match TargetsList::try_from(&rbuf[..offset]) {
                    Ok(targets) => {
                        log::info!("Targets: {:?}", targets);
                    }
                    Err(err) => {
                        log::error!("Error parsing targets: {:?}", err);
                    }
                }
                offset = 0;
            }
            Err(error) => {
                log::error!("Error reading UART: {:?}", error);
            }
        }
    }
}
