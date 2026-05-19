require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: Required command not found: ${command_name}" >&2
    exit 1
  fi
}

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
