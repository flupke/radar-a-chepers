# Agent Notes

This repo controls a Phoenix web app, a Raspberry Pi uploader, and ESP32-S3 radar firmware.

Before changing behavior, read `docs/workflows.md` for the current operational commands and hardware assumptions.

Key defaults:

- Pi host: `rshep.local`
- Normal deploy with the current RD03-D hardware: `./install.sh --radar-device rd03d`
- Local fake dev for the current RD03-D setup: `./start.sh --radar-device rd03d --fake-people --local-web`
- Local web with real Pi hardware: `./start.sh --radar-device rd03d --local-web --remote-uploader rshep.local`
- ESP USB serial for flashing/defmt logs: `/dev/ttyACM0`
- Pi-to-ESP config UART: Pi `/dev/serial0`, ESP RX `GPIO40`, ESP TX `GPIO41`
- ESP camera trigger GPIO: `GPIO42`

When using the remote-hardware dev workflow, stopping the local `start.sh` process should restart the Pi's normal `radar-uploader.service`. If it does not, run:

```sh
ssh rshep.local 'sudo systemctl restart radar-uploader.service'
```

## Working Together

Work directly from the user's prompt. Implement and verify changes in the
current checkout; use a separate workspace only when isolation is useful.

Use `jj` for local version-control operations. Keep changes focused and use
plain, descriptive commit messages. Push changes or create PRs when the user
asks for that delivery.

Report progress and decisions directly in the conversation. When hardware,
captures, credentials, or another external input is missing, explain what is
blocked and distinguish partial implementation from verified support.

Because this checkout may live under `main/` with agent workspaces under
`agents/`, plain `nix develop` from a workspace can resolve the wrong flake
path. When that happens, pass the flake path explicitly:

```sh
nix develop /home/flupke/src/radar-a-chepers/main --command <command>
```
