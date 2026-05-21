# Workflows

This project has three runtime pieces:

- Phoenix web app in `web/`
- Raspberry Pi uploader in `uploader/`
- ESP32-S3 radar firmware in `radar/`

## Normal Deploy

Deploy the uploader and ESP firmware to the Pi:

```sh
./install.sh
```

Defaults:

- SSH host: `rshep.local`
- ESP USB serial for flashing and firmware logs: `/dev/ttyACM0`
- Pi-to-ESP config UART: `/dev/serial0`

The install script always rebuilds the ESP firmware, flashes it before updating the uploader service, and restarts `radar-uploader.service`.

Deploy the web app to Fly:

```sh
make deploy-web
```

Deploy both:

```sh
make deploy-all
```

## Local Web With Fake Uploader

Use this when working on the admin UI without hardware:

```sh
./start.sh --fake-people --local-web
```

This starts Phoenix locally and runs the uploader in `--test-mode` against `http://localhost:4000`.

## Local Web With Real Pi Hardware

Use this when debugging the real radar through the local admin page:

```sh
./start.sh --local-web --remote-uploader rshep.local
```

This starts Phoenix locally, detects this machine's LAN IPv4 address, stops the Pi's normal `radar-uploader.service`, and runs the installed Pi uploader over SSH against the local web server.

If LAN IP detection is wrong, override it:

```sh
LOCAL_API_ENDPOINT_LAN=http://192.168.1.65:4000 ./start.sh --local-web --remote-uploader rshep.local
```

When the local `start.sh` process exits, it should restart the normal Pi service. If cleanup is interrupted, restore it manually:

```sh
ssh rshep.local 'sudo systemctl restart radar-uploader.service'
```

## Checking The Pi

Service status and recent logs:

```sh
ssh rshep.local 'systemctl --no-pager --full status radar-uploader.service'
ssh rshep.local 'journalctl -u radar-uploader.service -n 120 --no-pager'
```

Useful log markers:

- `Joined radar:config channel`: uploader connected to the web app.
- `Sending ESP trigger config on /dev/serial0`: uploader is using the Pi-to-ESP config UART.
- `ESP acknowledged trigger config`: ESP received and parsed the latest web config.
- `Radar target frame header observed during passive probe`: ESP sees RD03-D target frames.
- `Capture check ...`: ESP evaluated a target against the local trigger rules.

## Hardware Links

Pi-to-ESP config UART:

- Pi GPIO14/TXD, physical pin 8 -> ESP `GPIO40`
- Pi GPIO15/RXD, physical pin 10 <- ESP `GPIO41`
- Pi GND -> ESP GND

ESP trigger output:

- ESP `GPIO42` drives the camera trigger module.

Pi serial setup:

```sh
ssh rshep.local 'grep -Eo "console=[^ ]+" /boot/firmware/cmdline.txt || true'
ssh rshep.local 'grep -E "^(enable_uart=1|dtparam=uart0=on)" /boot/firmware/config.txt'
ssh rshep.local 'ls -l /dev/serial0 && readlink -f /dev/serial0'
```

Expected:

- no `console=serial...`
- `enable_uart=1`
- `/dev/serial0` exists

## Camera Debugging

USB to the camera is for `gphoto2` control/photo retrieval only. The camera still needs battery power or a dummy-battery power adapter.

When the camera battery is dead, continue radar-only debugging by pausing capture in the admin UI. Radar positions, uploader connection, ESP config ack, and capture-check logs can still be tested without taking photos.
