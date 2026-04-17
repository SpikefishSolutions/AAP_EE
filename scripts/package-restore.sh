#!/bin/bash
# ============================================================
# package-restore.sh — Reinstall user packages from snapshot
#
# Called from bootstrap.sh on every boot. Reads the delta files
# written by package-snapshot.sh and reinstalls using cached
# package data from the named Docker volumes (pip & npm caches).
#
# Fault-tolerant: logs errors but never blocks container startup.
# ============================================================

SNAPSHOT_DIR="/home/node/.local/share/opencode/packages"
LOG="[package-restore]"

# ── pip restore ─────────────────────────────────────────────
if [ -f "$SNAPSHOT_DIR/pip-packages.txt" ]; then
    COUNT=$(wc -l < "$SNAPSHOT_DIR/pip-packages.txt" | tr -d ' ')
    echo "$LOG Restoring $COUNT pip package(s)..."
    if /venv/bin/pip install --quiet -r "$SNAPSHOT_DIR/pip-packages.txt" 2>&1; then
        echo "$LOG pip restore complete"
    else
        echo "$LOG WARNING: pip restore had errors (non-fatal)" >&2
    fi
else
    echo "$LOG No pip snapshot to restore"
fi

# ── Fix cache ownership (named volumes can start root-owned) ──
if [ -d "/home/node/.npm" ]; then
    sudo chown -R "$(id -u):$(id -g)" /home/node/.npm 2>/dev/null || true
fi
if [ -d "/home/node/.cache/pip" ]; then
    sudo chown -R "$(id -u):$(id -g)" /home/node/.cache/pip 2>/dev/null || true
fi

# ── npm restore ─────────────────────────────────────────────
if [ -f "$SNAPSHOT_DIR/npm-packages.txt" ]; then
    if command -v npm &>/dev/null; then
        COUNT=$(wc -l < "$SNAPSHOT_DIR/npm-packages.txt" | tr -d ' ')
        echo "$LOG Restoring $COUNT npm package(s)..."
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if npm install -g "$pkg" --quiet 2>&1; then
                echo "$LOG npm: installed $pkg"
            else
                echo "$LOG WARNING: failed to install npm package '$pkg' (non-fatal)" >&2
            fi
        done < "$SNAPSHOT_DIR/npm-packages.txt"
        echo "$LOG npm restore complete"
    else
        echo "$LOG WARNING: npm not available, cannot restore npm packages" >&2
    fi
else
    echo "$LOG No npm snapshot to restore"
fi

exit 0
