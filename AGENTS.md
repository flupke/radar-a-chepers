# Agent Notes

This repo controls a Phoenix web app, a Raspberry Pi uploader, and ESP32-S3 radar firmware.

Before changing behavior, read `docs/workflows.md` for the current operational commands and hardware assumptions.

Key defaults:

- Pi host: `rshep.local`
- Normal deploy: `./install.sh`
- Local fake dev: `./start.sh --fake-people --local-web`
- Local web with real Pi hardware: `./start.sh --local-web --remote-uploader rshep.local`
- ESP USB serial for flashing/defmt logs: `/dev/ttyACM0`
- Pi-to-ESP config UART: Pi `/dev/serial0`, ESP RX `GPIO40`, ESP TX `GPIO41`
- ESP camera trigger GPIO: `GPIO42`

When using the remote-hardware dev workflow, stopping the local `start.sh` process should restart the Pi's normal `radar-uploader.service`. If it does not, run:

```sh
ssh rshep.local 'sudo systemctl restart radar-uploader.service'
```
