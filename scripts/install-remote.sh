#!/usr/bin/env bash
# Invoked as root on the Pi by install.sh, with output kept in staging/install.log.
set -euo pipefail

staging="$1"
app_dir="$2"
env_file="$3"
infractions_dir="$4"
radar_binary="$5"
espflash_binary="$6"
service_name="$7"
service_file="$8"
serial_port="$9"

backup="$staging/previous"
files=("$app_dir/uploader" "$radar_binary" "$espflash_binary" "$env_file" "$service_file")
existed=()
flash_attempted=0
enable_attempted=0

flash() {
  timeout --kill-after=10s 180s "$1" flash --chip esp32s3 --port "$serial_port" --non-interactive "$2"
}

recover() {
  local status="$1"
  local recovered=1
  local state index previous_flasher
  trap - EXIT HUP INT TERM
  set +e

  echo "error: Deployment failed; restoring the previous installation." >&2
  state="$(systemctl show --property=LoadState --value "$service_name")"
  if [ "$?" != 0 ] || { [ "$state" != not-found ] && ! systemctl stop "$service_name"; }; then
    echo "error: Cannot stop the uploader for recovery. Backups and logs remain in $staging; manual recovery is required." >&2
    exit "$status"
  fi

  if [ "$flash_attempted" = 1 ]; then
    previous_flasher="$staging/espflash"
    [ ! -x "$backup/2" ] || previous_flasher="$backup/2"
    if [ "${existed[1]}" != 1 ] || ! flash "$previous_flasher" "$backup/1"; then
      recovered=0
      echo "error: Could not restore the previous ESP firmware; the uploader will remain stopped." >&2
    fi
  fi

  # Undo any enable operation before removing a newly installed unit file.
  if [ "$enable_attempted" = 1 ] && [ "$was_enabled" = 0 ]; then
    systemctl disable "$service_name" || recovered=0
  fi
  for index in "${!files[@]}"; do
    if [ "${existed[$index]}" = 1 ]; then
      cp -p -- "$backup/$index" "${files[$index]}" || recovered=0
    else
      rm -f -- "${files[$index]}" || recovered=0
    fi
  done
  systemctl daemon-reload || recovered=0
  if [ "$was_enabled" = 1 ]; then
    systemctl enable "$service_name" || recovered=0
  fi

  if [ "$recovered" = 1 ] && [ "$was_active" = 1 ]; then
    systemctl start "$service_name" && systemctl is-active --quiet "$service_name" || recovered=0
  fi
  if [ "$recovered" = 1 ]; then
    echo "Previous installation restored. Deployment failure details remain in $staging/install.log." >&2
  else
    systemctl stop "$service_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    echo "error: Recovery is incomplete. The uploader is stopped and disabled to avoid running with mismatched firmware. Restore from $backup before restarting it; see $staging/install.log." >&2
  fi
  exit "$status"
}

# Complete preflight and backups before taking the working service offline.
for file in "$staging/uploader" "$staging/radar-a-chepers" "$staging/espflash" "$staging/uploader.env" "$staging/$service_name"; do
  test -s "$file"
done
test -x "$staging/espflash"
unit_state="$(systemctl show --property=LoadState --value "$service_name")"
was_active=0
was_enabled=0
if systemctl is-active --quiet "$service_name"; then was_active=1; fi
if systemctl is-enabled --quiet "$service_name"; then was_enabled=1; fi
mkdir -m 0700 -- "$backup"
for index in "${!files[@]}"; do
  if [ -e "${files[$index]}" ]; then
    cp -p -- "${files[$index]}" "$backup/$index"
    existed+=(1)
  else
    existed+=(0)
  fi
done

trap 'recover "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$unit_state" != not-found ]; then
  systemctl stop "$service_name"
fi
install -d -m 0755 -- "$app_dir" "${env_file%/*}" "$infractions_dir" "${radar_binary%/*}" "${espflash_binary%/*}" "${service_file%/*}"
flash_attempted=1
flash "$staging/espflash" "$staging/radar-a-chepers"

# The installed decoder ELF changes only after flashing succeeds. Keep all
# previous files until the replacement service has successfully started.
install -m 0755 -- "$staging/uploader" "$app_dir/uploader"
install -m 0644 -- "$staging/radar-a-chepers" "$radar_binary"
install -m 0755 -- "$staging/espflash" "$espflash_binary"
install -m 0600 -- "$staging/uploader.env" "$env_file"
install -m 0644 -- "$staging/$service_name" "$service_file"
systemctl daemon-reload
enable_attempted=1
systemctl enable "$service_name"
systemctl start "$service_name"
systemctl is-active --quiet "$service_name"

trap - EXIT HUP INT TERM
