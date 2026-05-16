#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FLY_APP="${FLY_APP:-rshep}"
FLY_APP_URL="${FLY_APP_URL:-https://${FLY_APP}.fly.dev}"
FLY_APP_URL="${FLY_APP_URL%/}"

LOCAL_API_ENDPOINT="${LOCAL_API_ENDPOINT:-http://localhost:4000}"
LOCAL_API_ENDPOINT="${LOCAL_API_ENDPOINT%/}"

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyACM0}"
RADAR_BINARY="${RADAR_BINARY:-${ROOT_DIR}/radar/target/xtensa-esp32s3-none-elf/debug/radar-a-chepers}"

FAKE_PEOPLE=0
LOCAL_WEB=0
START_WEB_ONLY="${START_WEB_ONLY:-0}"

CHILD_PIDS=()
SHUTTING_DOWN=0

usage() {
  cat <<EOF
Usage: ./start.sh [--fake-people] [--local-web]

By default, starts the uploader in live hardware mode connected to ${FLY_APP_URL}.

Options:
  --fake-people  Start the uploader with --test-mode.
  --local-web    Start the Phoenix web server locally and connect the uploader to it.
  -h, --help     Show this help.
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: Required command not found: ${command_name}" >&2
    exit 1
  fi
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

  exit "$status"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup $?' EXIT

wake_fly_app() {
  require_command curl

  echo "==> Waking Fly app (${FLY_APP})..."
  curl --silent --show-error --max-time 30 --output /dev/null "$FLY_APP_URL" || true
}

fetch_fly_secret() {
  local name="$1"
  local value

  if ! value="$(fly ssh console --app "$FLY_APP" -C "printenv ${name}" -q)"; then
    return 1
  fi

  value="${value//$'\r'/}"
  value="${value//$'\n'/}"

  printf '%s' "$value"
}

fetch_required_fly_secrets() {
  local names=("$@")
  local missing=()
  local name
  local value
  local attempt

  missing=()
  for name in "${names[@]}"; do
    if [ -z "${!name:-}" ]; then
      missing+=("$name")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  require_command fly
  wake_fly_app
  echo "==> Fetching secrets from Fly (${FLY_APP})..."

  for attempt in 1 2 3 4 5; do
    for name in "${names[@]}"; do
      if [ -n "${!name:-}" ]; then
        continue
      fi

      if value="$(fetch_fly_secret "$name")" && [ -n "$value" ]; then
        printf -v "$name" '%s' "$value"
        export "$name"
      fi
    done

    missing=()
    for name in "${names[@]}"; do
      if [ -z "${!name:-}" ]; then
        missing+=("$name")
      fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
      return
    fi

    if [ "$attempt" = 5 ]; then
      echo "error: Could not fetch required Fly secrets: ${missing[*]}" >&2
      echo "       Ensure app ${FLY_APP} is reachable and the secrets are set." >&2
      exit 1
    fi

    echo "==> Fly app is not ready yet; retrying..."
    sleep 2
  done
}

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
  )

  if [ "$FAKE_PEOPLE" = 1 ]; then
    args+=(--test-mode)
  else
    ensure_radar_binary
    args+=(--serial-port "$SERIAL_PORT" --elf-path "$RADAR_BINARY")
  fi

  (
    cd "$ROOT_DIR/uploader"
    export RUST_LOG="${RUST_LOG:-info}"
    exec cargo run --bin uploader -- "${args[@]}"
  ) &

  CHILD_PIDS+=("$!")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fake-people)
      FAKE_PEOPLE=1
      ;;
    --local-web)
      LOCAL_WEB=1
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

if [ "$START_WEB_ONLY" = 1 ]; then
  if [ "$LOCAL_WEB" != 1 ]; then
    echo "error: START_WEB_ONLY=1 requires --local-web" >&2
    exit 1
  fi

  run_web_foreground
fi

if [ "$LOCAL_WEB" = 1 ]; then
  API_ENDPOINT="$LOCAL_API_ENDPOINT"
  API_KEY="${API_KEY:-radar-dev-key}"
  start_web
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

start_uploader "$API_ENDPOINT" "$API_KEY"

set +e
wait -n "${CHILD_PIDS[@]}"
status="$?"
set -e

cleanup "$status"
