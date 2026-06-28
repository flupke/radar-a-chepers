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

## Parallel And Stacked Work

Keep implementation work out of the coordinator workspace. From `main/`, create
task workspaces under `../agents/` with `jj workspace add`, using the task's
stack parent as the revision:

```sh
jj workspace add ../agents/<task-slug> -r <parent-bookmark> -m "<clean task title>"
```

For a root task, `<parent-bookmark>` is usually `main`. For a dependent task,
use the bookmark of the PR it stacks on, such as `rc-edm.1/radar-interface`.

Use subagents for parallel tracks only when their write scopes are separate.
The coordinator owns `bw start`, `bw close`, `bw sync`, pushes, and GitHub PR
creation. Worker agents should edit only their assigned workspace, use `jj`,
and leave the working copy ready for review; they should not mutate beadwork
state or publish branches unless explicitly told to.

One `bw` task maps to one GitHub PR. For dependency chains, create stacked PRs
by setting each PR base to the parent task's branch, not only by naming the
branches similarly.

Do not put beadwork task IDs in commit/change titles or PR titles. Task IDs are
fine in branch names and PR bodies.

If a task cannot be completed because hardware data, captures, credentials, or
another external input is missing, do not close it. Record the blocker with
`bw comment`, add a useful label such as `blocked:hardware-data`, and leave the
task open. If partial work is worth preserving, publish it as a draft PR and
make the blocker explicit in the PR body.

Because this checkout may live under `main/` with agent workspaces under
`agents/`, plain `nix develop` from a workspace can resolve the wrong flake
path. When that happens, pass the flake path explicitly:

```sh
nix develop /home/flupke/src/radar-a-chepers/main --command <command>
```
