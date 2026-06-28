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

## Work Management

This project tracks work with `bw` (beadwork), which persists to git — plans,
progress, and decisions survive compaction, session boundaries, and context
loss.

ALWAYS run `bw prime` before starting work. Without it, you're missing workflow
context, current state, and repo hygiene warnings. Work done without priming
often conflicts with in-progress changes.

Committing, closing issues, and syncing are part of completing a task — not
separate actions requiring additional permission.

Use `jj` for local version-control operations and stack management. Do not use
raw `git` workflows unless `jj` cannot perform the required action.

Each `bw` task should land as its own GitHub PR. Do not bundle multiple task IDs
into one PR unless the user explicitly asks for that exception.

When `bw` tasks form a dependency chain, land them as stacked PRs in dependency
order so each PR is reviewable against its parent task's branch.
