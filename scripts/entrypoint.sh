#!/bin/bash
# ============================================================
# entrypoint.sh — Container entrypoint (runs as root)
#
# 1. Optionally remap the `node` UID/GID via PUID/PGID so
#    bind-mounted host directories have correct permissions.
# 2. Fix ownership of named volumes (they come up root-owned).
# 3. Run bootstrap.sh as `node` (restores snapshotted packages,
#    sets up git + gh auth).
# 4. Fork the periodic snapshot loop in the background.
# 5. Exec `opencode web` as `node` so it owns PID 1's signal
#    handling (tini is in front of us via the Dockerfile ENTRYPOINT).
# ============================================================
set -e

LOG="[entrypoint]"

_validate_id() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$LOG ERROR: $name must be a positive integer (got: $value)" >&2
        exit 1
    fi
    if [ "$value" = "0" ]; then
        echo "$LOG ERROR: $name=0 (root) is not allowed" >&2
        exit 1
    fi
}

# ── Optional UID/GID remap ──────────────────────────────────
if [ -n "${PGID:-}" ] && [ "$PGID" != "$(id -g node)" ]; then
    _validate_id PGID "$PGID"
    groupmod -o -g "$PGID" node
    echo "$LOG Set node GID to $PGID"
fi
if [ -n "${PUID:-}" ] && [ "$PUID" != "$(id -u node)" ]; then
    _validate_id PUID "$PUID"
    usermod -o -u "$PUID" node
    echo "$LOG Set node UID to $PUID"
fi

_chown_warn() {
    local label="$1"; shift
    local err
    if ! err=$(chown "$@" 2>&1); then
        echo "$LOG WARNING: chown (${label}) failed: ${err}" >&2
    elif [ -n "$err" ]; then
        echo "$LOG WARNING: chown (${label}) reported: ${err}" >&2
    fi
}

# ── Fix ownership if UID/GID changed ────────────────────────
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    _chown_warn "user dirs" -R node:node /home/node /venv /app
    if [ -d /workspace ]; then
        _chown_warn "workspace" node:node /workspace
    fi
fi

# ── Fix ownership of named volumes & cache dirs ─────────────
# Docker creates named volumes root-owned; opencode/pip/npm all
# need to write into them.
for d in /home/node/.cache \
         /home/node/.npm \
         /home/node/.local \
         /home/node/.config/opencode \
         /home/node/.local/share/opencode; do
    [ -d "$d" ] || continue
    _chown_warn "cache:$d" -R node:node "$d"
done

# ── Run bootstrap as `node` ─────────────────────────────────
runuser --preserve-environment -s /bin/bash node -c "/opt/opencode/scripts/bootstrap.sh"

# ── Fork snapshot loop ──────────────────────────────────────
runuser --preserve-environment -s /bin/bash node -c "/opt/opencode/scripts/snapshot-loop.sh" &
SNAPSHOT_PID=$!
echo "$LOG snapshot loop started (pid $SNAPSHOT_PID)"

# ── Exec opencode web as `node` ─────────────────────────────
# Use `exec` so tini (PID 1) reaps us directly and forwards signals.
# If caller passed a custom CMD, honor it; default to opencode web.
if [ "$#" -gt 0 ]; then
    exec runuser --preserve-environment -s /bin/bash node -c "$(printf '%q ' "$@")"
else
    exec runuser --preserve-environment -s /bin/bash node -c \
        "cd /workspace && exec opencode web --hostname 0.0.0.0"
fi
