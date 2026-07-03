#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FLY_APP="${FLY_APP:-rshep}"
FLY_APP_URL="${FLY_APP_URL:-https://${FLY_APP}.fly.dev}"
FLY_APP_URL="${FLY_APP_URL%/}"

. "$ROOT_DIR/scripts/fly-secrets.sh"

UPLOADER_TARGET="${UPLOADER_TARGET:-aarch64-unknown-linux-musl}"
UPLOADER_BINARY="${ROOT_DIR}/uploader/target/${UPLOADER_TARGET}/release/uploader"
ESPFLASH_BINARY="${ROOT_DIR}/.nix/espflash/${UPLOADER_TARGET}/bin/espflash"

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyACM0}"
CONFIG_SERIAL_PORT="${CONFIG_SERIAL_PORT:-/dev/serial0}"
RADAR_BINARY="${RADAR_BINARY:-${ROOT_DIR}/radar/target/xtensa-esp32s3-none-elf/debug/radar-a-chepers}"
RADAR_DEVICE="${RADAR_DEVICE:-}"

REMOTE="${REMOTE:-rshep.local}"
REMOTE_FROM_CLI=0
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/radar-a-chepers}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-${REMOTE_APP_DIR}/.env}"
REMOTE_INFRACTIONS_DIR="${REMOTE_INFRACTIONS_DIR:-/var/lib/radar-a-chepers/infractions}"
REMOTE_RADAR_BINARY="${REMOTE_RADAR_BINARY:-${REMOTE_APP_DIR}/radar-a-chepers}"
REMOTE_ESPFLASH_BINARY="/usr/local/bin/espflash"
REMOTE_SERVICE_NAME="${REMOTE_SERVICE_NAME:-radar-uploader.service}"
RUST_LOG="${RUST_LOG:-info}"

SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"

LOCAL_TMP_DIR=""

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [ -z "$value" ]; then
    echo "error: ${option} requires a value" >&2
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage: ./install.sh [options] [ssh-host]

Builds the uploader for Raspberry Pi 4, fetches RADAR_API_KEY from Fly.io,
copies the runtime files over SSH, and installs a systemd service.

Options:
  --host HOST                 SSH target. Default: ${REMOTE}
  --target TARGET             Rust target. Default: ${UPLOADER_TARGET}
  --serial-port PATH          ESP USB serial device for flashing/logs. Default: ${SERIAL_PORT}
  --config-serial-port PATH   Pi UART device used to send config to ESP.
                              Default: ${CONFIG_SERIAL_PORT}
  --radar-device DEVICE       Active radar device for this uploader connection: rd03d or ld2451.
                              RADAR_DEVICE can also provide this value.
  --radar-binary PATH         Local radar firmware ELF to copy.
                              Default: ${RADAR_BINARY}
  --remote-app-dir PATH       Remote install directory. Default: ${REMOTE_APP_DIR}
  --remote-env-file PATH      Remote environment file. Default: ${REMOTE_ENV_FILE}
  --remote-infractions PATH   Remote infractions directory. Default: ${REMOTE_INFRACTIONS_DIR}
  --remote-radar-binary PATH  Remote radar ELF path. Default: ${REMOTE_RADAR_BINARY}
  --service-name NAME         systemd service name. Default: ${REMOTE_SERVICE_NAME}
  -h, --help                  Show this help.

Environment:
  FLY_APP, FLY_APP_URL, API_ENDPOINT, API_KEY, REMOTE, SSH_BIN, SCP_BIN
EOF
}

cleanup() {
  if [ -n "$LOCAL_TMP_DIR" ] && [ -d "$LOCAL_TMP_DIR" ]; then
    rm -rf "$LOCAL_TMP_DIR"
  fi
}

trap cleanup EXIT

target_linker() {
  case "$1" in
    aarch64-unknown-linux-gnu)
      printf '%s\n' "aarch64-unknown-linux-gnu-gcc"
      ;;
    aarch64-unknown-linux-musl)
      printf '%s\n' "aarch64-unknown-linux-musl-gcc"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

target_ar() {
  case "$1" in
    aarch64-unknown-linux-gnu)
      printf '%s\n' "aarch64-unknown-linux-gnu-ar"
      ;;
    aarch64-unknown-linux-musl)
      printf '%s\n' "aarch64-unknown-linux-musl-ar"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

target_env_name() {
  local target="$1"
  target="${target//-/_}"
  printf '%s\n' "${target^^}"
}

validate_radar_device() {
  if [ -z "$RADAR_DEVICE" ]; then
    echo "error: --radar-device is required (rd03d or ld2451)" >&2
    exit 1
  fi

  case "$RADAR_DEVICE" in
    rd03d | ld2451)
      ;;
    *)
      echo "error: unsupported radar device: ${RADAR_DEVICE}" >&2
      echo "       expected one of: rd03d, ld2451" >&2
      exit 1
      ;;
  esac
}

run_cargo() {
  local workdir="$1"
  shift

  if command -v cargo >/dev/null 2>&1; then
    (cd "$workdir" && cargo "$@")
  elif command -v nix >/dev/null 2>&1; then
    (cd "$workdir" && nix develop "$ROOT_DIR" --command cargo "$@")
  else
    echo "error: Required command not found: cargo" >&2
    echo "       Install cargo or run this from the repo dev shell." >&2
    exit 1
  fi
}

build_uploader() {
  local linker

  linker="$(target_linker "$UPLOADER_TARGET")"

  echo "==> Building uploader for ${UPLOADER_TARGET}..."

  if [ -z "$linker" ] || command -v "$linker" >/dev/null 2>&1; then
    run_cargo "$ROOT_DIR/uploader" build --release --target "$UPLOADER_TARGET"
  elif command -v nix >/dev/null 2>&1; then
    (cd "$ROOT_DIR/uploader" && nix develop "$ROOT_DIR" --command cargo build --release --target "$UPLOADER_TARGET")
  else
    echo "error: Required linker not found: ${linker}" >&2
    echo "       Run this from the repo dev shell or install the target linker." >&2
    exit 1
  fi

  if [ ! -f "$UPLOADER_BINARY" ]; then
    echo "error: Expected uploader binary was not produced: ${UPLOADER_BINARY}" >&2
    exit 1
  fi
}

build_espflash() {
  local linker
  local ar
  local target_env

  if [ -x "$ESPFLASH_BINARY" ]; then
    return
  fi

  linker="$(target_linker "$UPLOADER_TARGET")"
  ar="$(target_ar "$UPLOADER_TARGET")"
  target_env="$(target_env_name "$UPLOADER_TARGET")"

  echo "==> Building espflash for ${UPLOADER_TARGET}..."

  if [ -z "$linker" ]; then
    echo "error: Unsupported espflash target: ${UPLOADER_TARGET}" >&2
    exit 1
  fi

  if command -v cargo >/dev/null 2>&1 && command -v "$linker" >/dev/null 2>&1 && command -v "$ar" >/dev/null 2>&1; then
    (
      cd "$ROOT_DIR"
      export "CARGO_TARGET_${target_env}_LINKER=$linker"
      export "CC_${target_env,,}=$linker"
      export "AR_${target_env,,}=$ar"
      cargo install espflash --locked --target "$UPLOADER_TARGET" --root "$(dirname "$(dirname "$ESPFLASH_BINARY")")"
    )
  elif command -v nix >/dev/null 2>&1; then
    (
      cd "$ROOT_DIR"
      nix develop "$ROOT_DIR" --command env \
        "CARGO_TARGET_${target_env}_LINKER=$linker" \
        "CC_${target_env,,}=$linker" \
        "AR_${target_env,,}=$ar" \
        cargo install espflash --locked --target "$UPLOADER_TARGET" --root "$(dirname "$(dirname "$ESPFLASH_BINARY")")"
    )
  else
    echo "error: Required linker not found: ${linker}" >&2
    echo "       Run this from the repo dev shell or install the target linker." >&2
    exit 1
  fi

  if [ ! -x "$ESPFLASH_BINARY" ]; then
    echo "error: Expected espflash binary was not produced: ${ESPFLASH_BINARY}" >&2
    exit 1
  fi
}

ensure_radar_binary() {
  echo "==> Building radar firmware ELF..."
  run_cargo "$ROOT_DIR/radar" build

  if [ ! -f "$RADAR_BINARY" ]; then
    echo "error: Expected radar firmware ELF was not produced: ${RADAR_BINARY}" >&2
    exit 1
  fi
}

resolve_api_config() {
  API_ENDPOINT="${API_ENDPOINT:-$FLY_APP_URL}"
  API_ENDPOINT="${API_ENDPOINT%/}"

  if [ -z "${API_KEY:-}" ]; then
    fetch_required_fly_secrets RADAR_API_KEY
    API_KEY="$RADAR_API_KEY"
  else
    wake_fly_app
  fi
}

write_env_file() {
  local env_file="$1"

  umask 077
  {
    printf 'API_ENDPOINT=%s\n' "$API_ENDPOINT"
    printf 'API_KEY=%s\n' "$API_KEY"
    printf 'INFRACTIONS_DIR=%s\n' "$REMOTE_INFRACTIONS_DIR"
    printf 'SERIAL_PORT=%s\n' "$SERIAL_PORT"
    printf 'CONFIG_SERIAL_PORT=%s\n' "$CONFIG_SERIAL_PORT"
    printf 'RADAR_DEVICE=%s\n' "$RADAR_DEVICE"
    printf 'ELF_PATH=%s\n' "$REMOTE_RADAR_BINARY"
    printf 'RUST_LOG=%s\n' "$RUST_LOG"
  } >"$env_file"
}

write_service_file() {
  local service_file="$1"

  cat >"$service_file" <<EOF
[Unit]
Description=Radar uploader
Wants=network-online.target
After=network-online.target

[Service]
Environment=RUST_LOG=${RUST_LOG}
WorkingDirectory=${REMOTE_APP_DIR}
ExecStart=${REMOTE_APP_DIR}/uploader --api-endpoint ${API_ENDPOINT} --api-key ${API_KEY} --infractions-dir ${REMOTE_INFRACTIONS_DIR} --radar-device ${RADAR_DEVICE} --serial-port ${SERIAL_PORT} --config-serial-port ${CONFIG_SERIAL_PORT} --elf-path ${REMOTE_RADAR_BINARY}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_remote() {
  local remote_tmp="/tmp/radar-a-chepers-install-$$"
  local env_file="${LOCAL_TMP_DIR}/uploader.env"
  local service_file="${LOCAL_TMP_DIR}/${REMOTE_SERVICE_NAME}"
  local remote_env_dir="${REMOTE_ENV_FILE%/*}"
  local remote_espflash_dir="${REMOTE_ESPFLASH_BINARY%/*}"

  require_command "$SSH_BIN"
  require_command "$SCP_BIN"

  write_env_file "$env_file"
  write_service_file "$service_file"

  echo "==> Creating remote staging directory..."
  "$SSH_BIN" "$REMOTE" "rm -rf '$remote_tmp' && mkdir -p '$remote_tmp'"

  echo "==> Copying uploader, radar ELF, espflash, environment, and service files..."
  "$SCP_BIN" \
    "$UPLOADER_BINARY" \
    "$RADAR_BINARY" \
    "$ESPFLASH_BINARY" \
    "$env_file" \
    "$service_file" \
    "$REMOTE:$remote_tmp/"

  echo "==> Installing runtime files and flashing radar firmware on ${REMOTE}..."
  "$SSH_BIN" "$REMOTE" "
    set -e
    sudo systemctl stop '$REMOTE_SERVICE_NAME' 2>/dev/null || true
    sudo install -d -m 0755 '$REMOTE_APP_DIR'
    sudo install -d -m 0755 '$remote_env_dir'
    sudo install -d -m 0755 '$REMOTE_INFRACTIONS_DIR'
    sudo install -d -m 0755 '$remote_espflash_dir'
    sudo install -m 0755 '$remote_tmp/$(basename "$ESPFLASH_BINARY")' '$REMOTE_ESPFLASH_BINARY'
    sudo install -m 0644 '$remote_tmp/$(basename "$RADAR_BINARY")' '$REMOTE_RADAR_BINARY'
    sudo '$REMOTE_ESPFLASH_BINARY' flash --chip esp32s3 --port '$SERIAL_PORT' --non-interactive '$REMOTE_RADAR_BINARY'
    sudo install -m 0755 '$remote_tmp/uploader' '$REMOTE_APP_DIR/uploader'
    sudo install -m 0600 '$remote_tmp/uploader.env' '$REMOTE_ENV_FILE'
    sudo install -m 0644 '$remote_tmp/$REMOTE_SERVICE_NAME' '/etc/systemd/system/$REMOTE_SERVICE_NAME'
    sudo systemctl daemon-reload
    sudo systemctl enable '$REMOTE_SERVICE_NAME'
    sudo systemctl restart '$REMOTE_SERVICE_NAME'
    rm -rf '$remote_tmp'
  "

  echo "==> Installed ${REMOTE_SERVICE_NAME} on ${REMOTE}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      require_option_value "$1" "${2:-}"
      REMOTE="$2"
      REMOTE_FROM_CLI=1
      shift
      ;;
    --target)
      require_option_value "$1" "${2:-}"
      UPLOADER_TARGET="$2"
      UPLOADER_BINARY="${ROOT_DIR}/uploader/target/${UPLOADER_TARGET}/release/uploader"
      ESPFLASH_BINARY="${ROOT_DIR}/.nix/espflash/${UPLOADER_TARGET}/bin/espflash"
      shift
      ;;
    --serial-port)
      require_option_value "$1" "${2:-}"
      SERIAL_PORT="$2"
      shift
      ;;
    --config-serial-port)
      require_option_value "$1" "${2:-}"
      CONFIG_SERIAL_PORT="$2"
      shift
      ;;
    --radar-device)
      require_option_value "$1" "${2:-}"
      RADAR_DEVICE="$2"
      shift
      ;;
    --radar-binary)
      require_option_value "$1" "${2:-}"
      RADAR_BINARY="$2"
      shift
      ;;
    --remote-app-dir)
      require_option_value "$1" "${2:-}"
      old_default_env_file="${REMOTE_APP_DIR}/.env"
      old_default_radar_binary="${REMOTE_APP_DIR}/radar-a-chepers"
      REMOTE_APP_DIR="$2"
      if [ "$REMOTE_ENV_FILE" = "$old_default_env_file" ]; then
        REMOTE_ENV_FILE="${REMOTE_APP_DIR}/.env"
      fi
      if [ "$REMOTE_RADAR_BINARY" = "$old_default_radar_binary" ]; then
        REMOTE_RADAR_BINARY="${REMOTE_APP_DIR}/radar-a-chepers"
      fi
      shift
      ;;
    --remote-env-file)
      require_option_value "$1" "${2:-}"
      REMOTE_ENV_FILE="$2"
      shift
      ;;
    --remote-infractions)
      require_option_value "$1" "${2:-}"
      REMOTE_INFRACTIONS_DIR="$2"
      shift
      ;;
    --remote-radar-binary)
      require_option_value "$1" "${2:-}"
      REMOTE_RADAR_BINARY="$2"
      shift
      ;;
    --service-name)
      require_option_value "$1" "${2:-}"
      REMOTE_SERVICE_NAME="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ "$REMOTE_FROM_CLI" -eq 1 ]; then
        echo "error: Multiple SSH hosts provided: ${REMOTE} and $1" >&2
        usage >&2
        exit 1
      fi
      REMOTE="$1"
      REMOTE_FROM_CLI=1
      ;;
  esac

  shift
done

validate_radar_device

LOCAL_TMP_DIR="$(mktemp -d)"

build_uploader
build_espflash
ensure_radar_binary
resolve_api_config
install_remote
