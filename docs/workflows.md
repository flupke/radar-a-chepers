# Workflows

This project has three runtime pieces:

- Phoenix web app in `web/`
- Raspberry Pi uploader in `uploader/`
- ESP32-S3 radar firmware in `radar/`

## Normal Deploy

Deploy the uploader and ESP firmware to the Pi:

```sh
./install.sh --radar-device rd03d
```

Defaults:

- SSH host: `rshep.local`
- ESP USB serial for flashing and firmware logs: `/dev/ttyACM0`
- Pi-to-ESP config UART: `/dev/serial0`
- Radar device: explicit `rd03d` or `ld2451` via `--radar-device`

The selected device controls both the firmware Cargo feature and uploader identity.
LD2451 software support is implemented; physical validation is still required.
See [LD2451](#ld2451) for wiring, protocol assumptions and verification.

The install script always rebuilds the ESP firmware, flashes it before updating the uploader service, and restarts `radar-uploader.service`.

Deployment backs up the installed firmware ELF, uploader, environment, service
unit, and flasher before stopping capture. It flashes the staged ELF before
replacing the installed decoder. If flashing or service startup fails, it
attempts to reflash and restore the previous installation. Failed deployments
retain `install.log` and the `previous/` backup directory under the printed Pi
staging path (`/tmp/radar-a-chepers-install.XXXXXXXX`). If rollback cannot restore
a matching firmware and runtime, the uploader stays stopped and disabled; use
those backups to recover before restarting it. Staging is temporary storage, so
copy the retained backup somewhere durable before rebooting an unrecovered Pi.

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
./start.sh --radar-device rd03d --fake-people --local-web
```

This starts Phoenix locally and runs the uploader in `--test-mode` against `http://localhost:4000`.

## Local Uploader With USB Hardware

With the ESP connected to this computer, `./start.sh --radar-device ld2451`
always builds and flashes the selected firmware before starting the uploader.
`SERIAL_PORT` selects the USB device; `CONFIG_SERIAL_PORT` selects the config
UART. The uploader decodes logs with the same ELF that was just flashed.
Firmware freshness is delegated to Cargo, not inferred from file timestamps.

## Local Web With Real Pi Hardware

Use this when debugging the real radar through the local admin page:

```sh
./start.sh --radar-device rd03d --local-web --remote-uploader rshep.local
```

This starts Phoenix locally, detects this machine's LAN IPv4 address, and runs
the installed Pi uploader against the local web server in a temporary
`radar-dev-uploader-*.service` unit. That unit stops the normal
`radar-uploader.service` while it owns the hardware.
Deploy that device with `./install.sh --radar-device <device>` first; remote
`start.sh` uses the firmware already installed on the Pi.

If LAN IP detection is wrong, override it:

```sh
LOCAL_API_ENDPOINT_LAN=http://192.168.1.65:4000 ./start.sh --radar-device rd03d --local-web --remote-uploader rshep.local
```

When `start.sh` exits, cleanup stops the temporary unit and all its uploader
processes before starting the normal Pi service. SSH disconnection or heartbeat
loss also ends the temporary unit: the heartbeat timeout is 20 seconds, with up
to 15 more seconds to force-stop an unresponsive uploader. Killing `start.sh`
without cleanup stops heartbeats within five seconds.

If recovery cannot be confirmed, stop any temporary units before restoring the
normal service manually:

```sh
ssh rshep.local 'sudo systemctl stop "radar-dev-uploader-*.service"; sudo systemctl restart radar-uploader.service'
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

The uploader and firmware correlate config acknowledgements by revision. The
uploader retries unacknowledged settings every second and refreshes the current
settings every 10 seconds, including after an ESP reset. Firmware starts with
capture paused until it receives valid settings. Deploy the firmware with the
uploader: the new uploader requires the revision-aware firmware, while the new
firmware also accepts the previous uploader's config commands during deployment.

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

## RD03-D Raw Frame Test

Use this when tracking disappears while someone runs through the radar field. Deploy the firmware, then follow the uploader logs while reproducing the dropout:

```sh
./install.sh --radar-device rd03d
ssh rshep.local 'journalctl -u radar-uploader.service -f --output=cat' | rg --line-buffered 'Radar raw frame|Radar raw target|Capture check|EVENTS: TRIGGER'
```

The ESP logs raw 30-byte RD03-D frames only around useful transitions:

- `state=empty`: a valid RD03-D frame was received, but all target slots were empty after at least one target had been seen.
- `state=targets`: targets reappeared after an empty or suspicious frame.
- `state=suspicious-speed`: a target speed was one of the suspicious `248`/`256` cm/s sentinel-like values seen in other RD03-D integrations.

If running produces `state=empty` or `state=suspicious-speed` while the ESP is still receiving valid raw frames, the dropout is inside the RD03-D module/tracker rather than the web display or uploader pipeline.

For field tests with fast people, use the full practical RD03-D range before blaming the trigger filters. The current useful starting point is `max_dist=8000` mm; shorter limits can reject the long-range jumps the module reports when its tracker starts to fail.

## LD2451

Build or deploy explicitly for the new module:

```sh
(cd radar && cargo build --no-default-features --features ld2451)
./install.sh --radar-device ld2451
./start.sh --radar-device ld2451 --local-web --remote-uploader rshep.local
```

For UI development without hardware:

```sh
./start.sh --radar-device ld2451 --fake-people --local-web
```

The radar UART uses 115200 baud (RD03-D remains at 256000). Connect module TX
(pin 4) to ESP GPIO18, and module RX (pin 5) to ESP GPIO17. Supply VIN (pin 1)
with 5V from a source capable of more than 200mA; connect GND (pin 2) to common
ground. UART signal levels are 3.3V. Pi config UART and GPIO42 trigger wiring
stay as described above. See the linked manufacturer manuals and exact
[protocol assumptions](../radar/fixtures/ld2451/README.md).

On boot, firmware configures detection over 100m in both directions, with a
0km/h minimum. Capture still uses the selected device's stored application
settings: its initial maximum capture distance is 10m. Adjust those settings
in the admin page for your field test; changing them does not reprogram the
module's sensitivity.

Hardware verification:

1. Deploy the web and uploader changes. Select LD2451 in the admin page and
   pause capture initially. Pausing stops new captures; already captured photos
   can still upload.
2. Confirm logs identify `device=ld2451 baud=115200`, see a target header during
   the passive probe, and report successful LD2451 configuration.
3. Save real empty/moving UART captures and verify distances, angles and speed
   against known motion. The manufacturer's direction table contradicts its
   example: the parser follows table 9 (1 = approaching), pending this check.
4. Change a capture setting and confirm `ESP acknowledged trigger config`.
   Confirm target events and LD2451 raw diagnostics reach the admin page.
5. With the camera ready, resume capture. Verify a pass inside the configured
   range/aperture and above the limit emits `EVENTS: TRIGGER`, pulses GPIO42,
   and delivers a photo. Check pause, cooldown and out-of-range rejection.

Software fixtures are synthetic. No physical capture, flashing, GPIO or camera
validation has been performed for LD2451 in this checkout.
