#!/usr/bin/env bash
# Runs inside the transient service created by start.sh. systemd owns and stops
# the whole process group, then restores the normal uploader with ExecStopPost.
set -euo pipefail

normal_service="$1"
shift

# stdin belongs to the SSH connection. Require a live connection before taking
# the hardware, and release it on EOF or a stalled connection (within 20s).
if ! IFS= read -r -t 20 heartbeat || [ "$heartbeat" != alive ]; then
  exit 1
fi

systemctl stop "$normal_service"
"$@" </dev/null &
uploader_pid=$!

while IFS= read -r -t 20 heartbeat && [ "$heartbeat" = alive ]; do
  if ! kill -0 "$uploader_pid" 2>/dev/null; then
    wait "$uploader_pid"
    exit 1
  fi
done

echo "Development connection closed or timed out; restoring the normal uploader." >&2
exit 1
