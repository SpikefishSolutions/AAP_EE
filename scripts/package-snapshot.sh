#!/bin/bash
# ============================================================
# package-snapshot.sh — Capture pip/npm packages beyond baseline
#
# Diffs the current installed packages against the build-time
# baseline and writes the delta to the persisted data dir so a
# rebuilt container restores exactly what the user added.
# ============================================================
set -euo pipefail

BASELINE_DIR="/opt/opencode/baseline"
SNAPSHOT_DIR="/home/node/.local/share/opencode/packages"
mkdir -p "$SNAPSHOT_DIR"

LOG="[snapshot]"

# ── pip snapshot ────────────────────────────────────────────
CURRENT_PIP=$(/venv/bin/pip freeze 2>/dev/null || true)
BASELINE_PIP=""
[ -f "$BASELINE_DIR/pip-baseline.txt" ] && BASELINE_PIP=$(cat "$BASELINE_DIR/pip-baseline.txt")

DELTA_PIP=$(comm -23 <(echo "$CURRENT_PIP" | sort) <(echo "$BASELINE_PIP" | sort) | grep -v '^$' || true)

if [ -n "$DELTA_PIP" ]; then
    echo "$DELTA_PIP" > "$SNAPSHOT_DIR/pip-packages.txt"
    COUNT=$(echo "$DELTA_PIP" | wc -l | tr -d ' ')
    echo "$LOG pip: $COUNT package(s) beyond baseline"
else
    rm -f "$SNAPSHOT_DIR/pip-packages.txt"
    echo "$LOG pip: no extra packages"
fi

# ── npm snapshot ────────────────────────────────────────────
if command -v npm &>/dev/null; then
    CURRENT_NPM=$(npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -I{} basename {} | sort || true)

    BASELINE_NPM=""
    if [ -f "$BASELINE_DIR/npm-baseline.txt" ]; then
        BASELINE_NPM=$(python3 -c "
import json
try:
    d = json.load(open('$BASELINE_DIR/npm-baseline.txt'))
    for name in sorted(d.get('dependencies', {}).keys()):
        print(name)
except Exception:
    pass
" 2>/dev/null || true)
    fi

    DELTA_NPM=$(comm -23 <(echo "$CURRENT_NPM" | sort) <(echo "$BASELINE_NPM" | sort) | grep -v '^$' || true)

    if [ -n "$DELTA_NPM" ]; then
        echo "$DELTA_NPM" > "$SNAPSHOT_DIR/npm-packages.txt"
        COUNT=$(echo "$DELTA_NPM" | wc -l | tr -d ' ')
        echo "$LOG npm: $COUNT package(s) beyond baseline"
    else
        rm -f "$SNAPSHOT_DIR/npm-packages.txt"
        echo "$LOG npm: no extra packages"
    fi
else
    echo "$LOG npm: not available, skipping"
fi
