# Uploader

This is a standalone Rust application that watches for new photos in a directory and uploads them to the web server.

Pending captures are retried at startup and every 10 seconds. Camera photos are
matched using EXIF capture timestamps, so synchronize the camera clock with the
Pi before use (UTC when EXIF has no timezone). Ambiguous matches remain pending.
Keep the `.uploaded` metadata receipts and camera download cache when restarting
the uploader. See [capture recovery and camera time](../docs/workflows.md#capture-recovery-and-camera-time)
for clock verification, retry behavior, and cache reset after card changes.

## Configuration

The uploader is configured via CLI flags:

- `--api-endpoint`: The URL of the API endpoint to upload photos to.
- `--api-key`: The authentication key for the API endpoint.
- `--infractions-dir`: The directory where pending infraction photos and JSON are stored.
- `--serial-port`: The ESP USB serial device used for firmware logs, for example `/dev/ttyACM0`.
- `--config-serial-port`: The Pi UART device used to send trigger config to the ESP, for example `/dev/serial0`.
- `--elf-path`: The radar firmware ELF used for defmt decoding.
- `--radar-device`: Required device identity, `rd03d` or `ld2451`, including in test mode.
- `--test-mode`: Run with simulated radar data.

## Raspberry Pi 4 build

The repo dev shell provides the Rust targets and linkers for Raspberry Pi 4 builds. Build the static ARM64 binary with:

```sh
cargo build --release --target aarch64-unknown-linux-musl
```

The binary is written to `target/aarch64-unknown-linux-musl/release/uploader` and can be copied to a 64-bit Raspberry Pi OS install.

To build and install it over SSH with a systemd service:

```sh
../install.sh --radar-device rd03d rshep.local
```
