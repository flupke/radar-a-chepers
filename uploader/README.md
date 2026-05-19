# Uploader

This is a standalone Rust application that watches for new photos in a directory and uploads them to the web server.

## Configuration

The uploader is configured via CLI flags:

- `--api-endpoint`: The URL of the API endpoint to upload photos to.
- `--api-key`: The authentication key for the API endpoint.
- `--infractions-dir`: The directory where pending infraction photos and JSON are stored.
- `--serial-port`: The radar serial device, for example `/dev/ttyACM0`.
- `--elf-path`: The radar firmware ELF used for defmt decoding.
- `--test-mode`: Run with simulated radar data.

## Raspberry Pi 4 build

The repo dev shell provides the Rust targets and linkers for Raspberry Pi 4 builds. Build the static ARM64 binary with:

```sh
cargo build --release --target aarch64-unknown-linux-musl
```

The binary is written to `target/aarch64-unknown-linux-musl/release/uploader` and can be copied to a 64-bit Raspberry Pi OS install.

To build and install it over SSH with a systemd service:

```sh
../install.sh pi@raspberrypi.local
```
