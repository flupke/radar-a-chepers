#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FLY_APP="${FLY_APP:-rshep}"
FLY_APP_URL="${FLY_APP_URL:-https://${FLY_APP}.fly.dev}"
FLY_APP_URL="${FLY_APP_URL%/}"

. "$ROOT_DIR/scripts/fly-secrets.sh"

LOCAL_API_ENDPOINT="${LOCAL_API_ENDPOINT:-http://localhost:4000}"
LOCAL_API_ENDPOINT="${LOCAL_API_ENDPOINT%/}"

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyACM0}"
CONFIG_SERIAL_PORT="${CONFIG_SERIAL_PORT:-/dev/serial0}"
RADAR_BINARY="${RADAR_BINARY:-${ROOT_DIR}/radar/target/xtensa-esp32s3-none-elf/debug/radar-a-chepers}"
RADAR_DEVICE="${RADAR_DEVICE:-}"

SSH_BIN="${SSH_BIN:-ssh}"
REMOTE_UPLOADER_HOST="${REMOTE_UPLOADER_HOST:-}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/radar-a-chepers}"
REMOTE_INFRACTIONS_DIR="${REMOTE_INFRACTIONS_DIR:-/var/lib/radar-a-chepers/infractions}"
REMOTE_RADAR_BINARY="${REMOTE_RADAR_BINARY:-${REMOTE_APP_DIR}/radar-a-chepers}"
REMOTE_SERVICE_NAME="${REMOTE_SERVICE_NAME:-radar-uploader.service}"

FAKE_PEOPLE=0
LOCAL_WEB=0
START_WEB_ONLY="${START_WEB_ONLY:-0}"

CHILD_PIDS=()
SHUTTING_DOWN=0
REMOTE_UPLOADER_STARTED=0

usage() {
  cat <<EOF
Usage: ./start.sh --radar-device DEVICE [--fake-people] [--local-web] [--remote-uploader HOST]

By default, starts the uploader in live hardware mode connected to ${FLY_APP_URL}.

Options:
  --fake-people           Start the uploader with --test-mode.
  --local-web             Start the Phoenix web server locally and connect the uploader to it.
  --remote-uploader HOST  With --local-web, run the installed Pi uploader over SSH and
                          point it at this machine's LAN URL.
  --radar-device DEVICE   Active radar device for this uploader connection: rd03d or ld2451.
  SERIAL_PORT and CONFIG_SERIAL_PORT override the live hardware serial devices.
  RADAR_DEVICE can also provide --radar-device.
  LOCAL_API_ENDPOINT_LAN overrides the URL given to the remote Pi.
  -h, --help              Show this help.
EOF
}

shell_quote() {
  printf '%q' "$1"
}

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [ -z "$value" ]; then
    echo "error: ${option} requires a value" >&2
    exit 1
  fi
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

cleanup() {
  local status="${1:-$?}"

  trap - INT TERM EXIT

  if [ "$SHUTTING_DOWN" = 1 ]; then
    exit "$status"
  fi

  SHUTTING_DOWN=1

  if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
    echo "==> Shutting down..."
    kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait "${CHILD_PIDS[@]}" 2>/dev/null || true
  fi

  if [ "$REMOTE_UPLOADER_STARTED" = 1 ]; then
    echo "==> Restarting ${REMOTE_SERVICE_NAME} on ${REMOTE_UPLOADER_HOST}..."
    "$SSH_BIN" "$REMOTE_UPLOADER_HOST" \
      "sudo systemctl restart $(shell_quote "$REMOTE_SERVICE_NAME")" 2>/dev/null || true
  fi

  exit "$status"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup $?' EXIT

wait_for_url() {
  local url="$1"
  local timeout_seconds="${2:-60}"
  local elapsed=0

  require_command curl

  echo "==> Waiting for ${url}..."

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if curl --silent --fail --max-time 2 --output /dev/null "$url"; then
      return
    fi

    elapsed=$((elapsed + 1))
    sleep 1
  done

  echo "error: Timed out waiting for ${url}" >&2
  exit 1
}

run_web_foreground() {
  fetch_required_fly_secrets GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET

  cd "$ROOT_DIR/web"
  mix ecto.create --quiet 2>/dev/null || true
  mix ecto.migrate --quiet
  FLY_APP="$FLY_APP" FLY_APP_URL="$FLY_APP_URL" exec mix phx.server
}

start_web() {
  fetch_required_fly_secrets GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET

  (
    cd "$ROOT_DIR/web"
    mix ecto.create --quiet 2>/dev/null || true
    mix ecto.migrate --quiet
    FLY_APP="$FLY_APP" FLY_APP_URL="$FLY_APP_URL" exec mix phx.server
  ) &

  CHILD_PIDS+=("$!")
  wait_for_url "${LOCAL_API_ENDPOINT}/"
}

local_api_port() {
  local without_scheme="${LOCAL_API_ENDPOINT#*://}"
  local host_port="${without_scheme%%/*}"

  if [[ "$host_port" == *:* ]]; then
    printf '%s\n' "${host_port##*:}"
  elif [[ "$LOCAL_API_ENDPOINT" == https://* ]]; then
    printf '%s\n' "443"
  else
    printf '%s\n' "80"
  fi
}

detect_lan_host() {
  local host

  if [ -n "${LOCAL_WEB_LAN_HOST:-}" ]; then
    printf '%s\n' "$LOCAL_WEB_LAN_HOST"
    return
  fi

  if command -v ip >/dev/null 2>&1 && [ -n "$REMOTE_UPLOADER_HOST" ]; then
    host="$REMOTE_UPLOADER_HOST"

    if command -v getent >/dev/null 2>&1; then
      host="$(getent ahostsv4 "$REMOTE_UPLOADER_HOST" | awk '{print $1; exit}')"
      host="${host:-$REMOTE_UPLOADER_HOST}"
    fi

    host="$(
      ip -4 route get "$host" 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )"

    if [ -n "$host" ]; then
      printf '%s\n' "$host"
      return
    fi
  fi

  if command -v hostname >/dev/null 2>&1; then
    host="$(hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+$/) {print $i; exit}}')"
    if [ -n "$host" ]; then
      printf '%s\n' "$host"
      return
    fi
  fi

  echo "error: Could not detect this machine's LAN IP." >&2
  echo "       Set LOCAL_API_ENDPOINT_LAN=http://<this-machine-ip>:$(local_api_port)." >&2
  exit 1
}

url_host() {
  local host="$1"

  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

local_api_endpoint_for_lan() {
  if [ -n "${LOCAL_API_ENDPOINT_LAN:-}" ]; then
    printf '%s\n' "${LOCAL_API_ENDPOINT_LAN%/}"
    return
  fi

  printf 'http://%s:%s\n' "$(url_host "$(detect_lan_host)")" "$(local_api_port)"
}

ensure_radar_binary() {
  local newer_source

  if [ ! -f "$RADAR_BINARY" ]; then
    newer_source=1
  else
    newer_source="$(find "$ROOT_DIR/radar" -name '*.rs' -newer "$RADAR_BINARY" -print -quit)"
  fi

  if [ -n "$newer_source" ]; then
    echo "==> Building and flashing radar firmware..."
    (cd "$ROOT_DIR/radar" && cargo espflash flash)
  fi
}

start_uploader() {
  local api_endpoint="$1"
  local api_key="$2"
  local infractions_dir
  local -a args

  if [ -n "${INFRACTIONS_DIR:-}" ]; then
    infractions_dir="$INFRACTIONS_DIR"
  elif [ "$FAKE_PEOPLE" = 1 ]; then
    infractions_dir="/tmp/infractions"
  else
    infractions_dir="$ROOT_DIR/infractions"
  fi

  mkdir -p "$infractions_dir"

  args=(
    --api-endpoint "$api_endpoint"
    --api-key "$api_key"
    --infractions-dir "$infractions_dir"
    --radar-device "$RADAR_DEVICE"
  )

  if [ "$FAKE_PEOPLE" = 1 ]; then
    args+=(--test-mode)
  else
    ensure_radar_binary
    args+=(
      --serial-port "$SERIAL_PORT"
      --config-serial-port "$CONFIG_SERIAL_PORT"
      --elf-path "$RADAR_BINARY"
    )
  fi

  (
    cd "$ROOT_DIR/uploader"
    export RUST_LOG="${RUST_LOG:-info}"
    exec cargo run --bin uploader -- "${args[@]}"
  ) &

  CHILD_PIDS+=("$!")
}

start_remote_uploader() {
  local api_endpoint="$1"
  local api_key="$2"
  local command

  require_command "$SSH_BIN"

  command=$(
    printf 'set -eu; '
    printf 'sudo systemctl stop %s 2>/dev/null || true; ' "$(shell_quote "$REMOTE_SERVICE_NAME")"
    printf 'exec sudo env RUST_LOG=%s %s ' \
      "$(shell_quote "${RUST_LOG:-info}")" \
      "$(shell_quote "${REMOTE_APP_DIR}/uploader")"
    printf '%s %s ' "--api-endpoint" "$(shell_quote "$api_endpoint")"
    printf '%s %s ' "--api-key" "$(shell_quote "$api_key")"
    printf '%s %s ' "--infractions-dir" "$(shell_quote "$REMOTE_INFRACTIONS_DIR")"
    printf '%s %s ' "--radar-device" "$(shell_quote "$RADAR_DEVICE")"
    printf '%s %s ' "--serial-port" "$(shell_quote "$SERIAL_PORT")"
    printf '%s %s ' "--config-serial-port" "$(shell_quote "$CONFIG_SERIAL_PORT")"
    printf '%s %s' "--elf-path" "$(shell_quote "$REMOTE_RADAR_BINARY")"
  )

  echo "==> Starting uploader on ${REMOTE_UPLOADER_HOST} against ${api_endpoint}..."
  "$SSH_BIN" "$REMOTE_UPLOADER_HOST" "$command" &
  CHILD_PIDS+=("$!")
  REMOTE_UPLOADER_STARTED=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fake-people)
      FAKE_PEOPLE=1
      ;;
    --local-web)
      LOCAL_WEB=1
      ;;
    --remote-uploader)
      require_option_value "$1" "${2:-}"
      REMOTE_UPLOADER_HOST="$2"
      shift
      ;;
    --radar-device)
      require_option_value "$1" "${2:-}"
      RADAR_DEVICE="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac

  shift
done

if [ -n "$REMOTE_UPLOADER_HOST" ] && [ "$LOCAL_WEB" != 1 ]; then
  echo "error: --remote-uploader requires --local-web" >&2
  exit 1
fi

if [ -n "$REMOTE_UPLOADER_HOST" ] && [ "$FAKE_PEOPLE" = 1 ]; then
  echo "error: --remote-uploader cannot be combined with --fake-people" >&2
  exit 1
fi

if [ "$START_WEB_ONLY" = 1 ]; then
  if [ "$LOCAL_WEB" != 1 ]; then
    echo "error: START_WEB_ONLY=1 requires --local-web" >&2
    exit 1
  fi

  if [ -n "$REMOTE_UPLOADER_HOST" ]; then
    echo "error: START_WEB_ONLY=1 cannot be combined with --remote-uploader" >&2
    exit 1
  fi

  run_web_foreground
fi

validate_radar_device

if [ "$LOCAL_WEB" = 1 ]; then
  API_ENDPOINT="$LOCAL_API_ENDPOINT"
  API_KEY="${API_KEY:-radar-dev-key}"
  start_web
  if [ -n "$REMOTE_UPLOADER_HOST" ]; then
    API_ENDPOINT="$(local_api_endpoint_for_lan)"
  fi
elif [ -n "${API_ENDPOINT:-}" ]; then
  API_ENDPOINT="${API_ENDPOINT%/}"
  API_KEY="${API_KEY:-radar-dev-key}"
else
  API_ENDPOINT="$FLY_APP_URL"

  if [ -z "${API_KEY:-}" ]; then
    fetch_required_fly_secrets RADAR_API_KEY
    API_KEY="$RADAR_API_KEY"
  else
    wake_fly_app
  fi
fi

if [ -n "$REMOTE_UPLOADER_HOST" ]; then
  start_remote_uploader "$API_ENDPOINT" "$API_KEY"
else
  start_uploader "$API_ENDPOINT" "$API_KEY"
fi

set +e
wait -n "${CHILD_PIDS[@]}"
status="$?"
set -e

cleanup "$status"
