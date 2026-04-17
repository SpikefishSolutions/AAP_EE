#!/bin/bash
# ============================================================
# snapshot-loop.sh — Periodic package snapshot daemon
#
# Calls package-snapshot.sh every PACKAGE_SNAPSHOT_INTERVAL
# seconds (default 300). Set the interval to 0 to disable
# periodic snapshots (you can still snapshot on demand via
# `opencode-snapshot` or the SIGTERM shutdown hook).
#
# Runs as the `node` user and is forked into the background
# from entrypoint.sh.
# ============================================================
set -u

INTERVAL="${PACKAGE_SNAPSHOT_INTERVAL:-300}"
SCRIPT="/opt/opencode/scripts/package-snapshot.sh"

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "[snapshot-loop] ERROR: PACKAGE_SNAPSHOT_INTERVAL must be an integer (got: $INTERVAL)" >&2
    exit 1
fi

if [ "$INTERVAL" -eq 0 ]; then
    echo "[snapshot-loop] PACKAGE_SNAPSHOT_INTERVAL=0, periodic snapshots disabled"
    exit 0
fi

echo "[snapshot-loop] Starting (interval: ${INTERVAL}s)"

# Snapshot on SIGTERM so `docker compose down` always captures the
# current state before the container is torn down.
trap 'echo "[snapshot-loop] Shutdown snapshot..."; "$SCRIPT" || true; exit 0' TERM INT

while true; do
    sleep "$INTERVAL" &
    # `wait` so the trap fires promptly instead of blocking for the full sleep
    wait $!
    "$SCRIPT" || echo "[snapshot-loop] WARNING: snapshot run failed (non-fatal)" >&2
done
