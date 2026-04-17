#!/bin/bash
# ============================================================
# bootstrap.sh — First-run + per-boot initialization
#
# Invoked by entrypoint.sh as the `node` user. Idempotent:
# safe to run on every boot. The sentinel file gates one-shot
# work from per-boot work.
# ============================================================
set -e

NODE_HOME="/home/node"
OPENCODE_CONFIG="${NODE_HOME}/.config/opencode"
OPENCODE_DATA="${NODE_HOME}/.local/share/opencode"
SENTINEL="${OPENCODE_DATA}/.bootstrapped"

LOG="[bootstrap]"

# ── Always: ensure directory structure exists ────────────────
mkdir -p "${OPENCODE_CONFIG}"
mkdir -p "${OPENCODE_DATA}"
mkdir -p "${OPENCODE_DATA}/packages"
mkdir -p /workspace

# ── Always: restore user-installed packages from snapshot ────
/opt/opencode/scripts/package-restore.sh || \
    echo "$LOG WARNING: package restore failed (non-fatal)" >&2

# ── Always: apply git identity if provided ───────────────────
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}"
fi

# ── Always: git credential store (persisted under opencode data) ──
GIT_CRED_FILE="${OPENCODE_DATA}/.git-credentials"
git config --global credential.helper "store --file=${GIT_CRED_FILE}"

# ── Always: GitHub CLI token (if provided) ───────────────────
if [ -n "${GH_TOKEN:-}" ]; then
    echo "$LOG Configuring GitHub CLI auth..."
    GH_ENV="${NODE_HOME}/.config/gh/gh_env.sh"
    mkdir -p "${NODE_HOME}/.config/gh"
    echo "export GH_TOKEN=\"${GH_TOKEN}\"" > "${GH_ENV}"
    chmod 600 "${GH_ENV}"
    for rc_file in "${NODE_HOME}/.bashrc" "${NODE_HOME}/.profile"; do
        if ! grep -q "gh_env.sh" "${rc_file}" 2>/dev/null; then
            echo '[ -f ~/.config/gh/gh_env.sh ] && . ~/.config/gh/gh_env.sh' >> "${rc_file}"
        fi
    done
    # HTTPS credentials for plain git
    echo "https://x-access-token:${GH_TOKEN}@github.com" > "${GIT_CRED_FILE}"
    chmod 600 "${GIT_CRED_FILE}"
fi

# ── First-run only below this point ──────────────────────────
if [ -f "${SENTINEL}" ]; then
    echo "$LOG Already bootstrapped, skipping first-run tasks."
    exit 0
fi

echo "$LOG First run detected — running initial setup..."

# (Space for first-run-only work — e.g., seeding default opencode
# config templates. Left empty for now.)

date -Iseconds > "${SENTINEL}"
echo "$LOG First-run setup complete."
