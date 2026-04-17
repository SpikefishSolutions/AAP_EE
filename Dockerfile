# ============================================================
# opencode-docker — Development environment running `opencode web`
#
# Layered after the multiplex base+python Dockerfiles:
#   * Ubuntu 24.04 (digest-pinned)
#   * System + Python build dependencies
#   * Node.js 20 LTS (for opencode)
#   * Python venv with full dev toolchain
#   * Persistent pip & npm caches owned by the runtime user
#   * opencode installed globally via npm
# ============================================================

# Pin by digest — same snapshot used by multiplex (2026-04-14)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ---------- 0. HTTP(S) proxy plumbing ----------
# Passed in from docker-compose `build.args`. Empty by default — a no-op
# when you're not behind a proxy. Both upper- and lower-case forms are
# exported because tooling is inconsistent about which one it reads
# (apt/curl: lowercase; Go/Node/git: uppercase).
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY=""
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY}

# Make Node and Python honour the system trust store (where
# update-ca-certificates installs custom certs dropped into ./certs/).
# Without these, Node uses its bundled CA list and Python's `requests`
# uses certifi — both miss corporate / MITM roots.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# ---------- 1. Base system deps (from multiplex base Dockerfile) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    ca-certificates \
    git \
    procps \
    tini \
    tmux \
    openssh-server \
    net-tools \
    sudo \
    gh \
    ripgrep \
    bat \
    tree \
    fd-find \
    fzf \
    git-delta \
    less \
    jq \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ---------- 2. Python build deps (from multiplex python variant) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3-dev \
    libffi-dev \
    libssl-dev \
    libpq-dev \
    libmysqlclient-dev \
    libsqlite3-dev \
    libxml2-dev \
    libxslt1-dev \
    libcurl4-openssl-dev \
    libyaml-dev \
    libbz2-dev \
    libreadline-dev \
    zlib1g-dev \
    liblzma-dev \
    libncurses5-dev \
    libgdbm-dev \
    tk-dev \
    uuid-dev \
    && rm -rf /var/lib/apt/lists/*

# ---------- 2b. Custom CA certificates (for MITM / corporate proxies) ----------
# Drop PEM-format root certs into ./certs/ on the host (filenames must end in
# `.crt`). An empty certs/ directory is a no-op. Required for TLS interception
# proxies, private package registries with self-signed certs, etc.
COPY certs/ /usr/local/share/ca-certificates/opencode-extra/
RUN update-ca-certificates

# ---------- 3. Node.js 20 LTS (required by opencode) ----------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---------- 4. Runtime user (non-root) ----------
# The ubuntu:24.04 image ships with a default `ubuntu` user at uid/gid 1000.
# Remove it so we can claim 1000:1000 for our own `node` user.
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g 1000 node && \
    useradd -u 1000 -g node -m -s /bin/bash node && \
    echo "node ALL=(root) NOPASSWD: /usr/bin/apt, /usr/bin/apt-get" > /etc/sudoers.d/node-apt && \
    chmod 0440 /etc/sudoers.d/node-apt

# ---------- 5. Python venv + pip deps (base + python variant merged) ----------
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python3 -m venv /venv \
    && /venv/bin/pip install --no-cache-dir --upgrade pip \
    && /venv/bin/pip install --no-cache-dir -r /app/requirements.txt \
    && chown -R node:node /venv

# ---------- 6. Persistent install methodology (from multiplex) ----------
# npm global prefix set to a user-writable location so global installs
# don't need root and end up on PATH at /home/node/.local/bin.
# Also thread proxy settings into npm's own config so `npm install -g`
# works behind MITM/corporate proxies. Guarded so the lines are no-ops
# when the proxy ARGs are empty.
RUN npm config -g set prefix /home/node/.local \
    && if [ -n "${HTTP_PROXY}" ];  then npm config -g set proxy       "${HTTP_PROXY}";  fi \
    && if [ -n "${HTTPS_PROXY}" ]; then npm config -g set https-proxy "${HTTPS_PROXY}"; fi \
    && if [ -n "${NO_PROXY}" ];    then npm config -g set noproxy     "${NO_PROXY}";    fi

# Cache directories — mounted as named volumes in docker-compose so they
# survive `docker compose down` and across image rebuilds.
RUN mkdir -p /home/node/.cache/pip \
    && mkdir -p /home/node/.npm \
    && mkdir -p /home/node/.local/bin \
    && mkdir -p /home/node/.local/lib \
    && chown -R node:node /home/node/.cache /home/node/.npm /home/node/.local

# Package baselines — lets tooling diff user-installed packages from the image default.
RUN mkdir -p /opt/opencode/baseline \
    && /venv/bin/pip freeze > /opt/opencode/baseline/pip-baseline.txt \
    && npm list -g --depth=0 --json > /opt/opencode/baseline/npm-baseline.txt 2>/dev/null \
       || echo '{}' > /opt/opencode/baseline/npm-baseline.txt \
    && chown -R node:node /opt/opencode/baseline

# ---------- 7. opencode ----------
# Installed via the official shell installer (curl | bash) rather than npm.
# Both channels ship the same prebuilt native binary, but the installer is
# the project's canonical method. Lands at /home/node/.opencode/bin/opencode.
# `--no-modify-path` because we manage PATH explicitly below.
USER node
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
USER root

# ---------- 8. Workspace dir ----------
RUN mkdir -p /workspace && chown node:node /workspace

# ---------- 9. Scripts (bootstrap, entrypoint, package snapshot/restore) ----------
COPY scripts/ /opt/opencode/scripts/
RUN chmod +x /opt/opencode/scripts/*.sh /opt/opencode/scripts/opencode-snapshot \
    && ln -sf /opt/opencode/scripts/opencode-snapshot /usr/local/bin/opencode-snapshot

# ---------- 10. PATH & env ----------
ENV PATH="/opt/opencode/scripts:/home/node/.opencode/bin:/home/node/.local/bin:/venv/bin:$PATH"
ENV HOME="/home/node"

RUN echo 'export PATH="/opt/opencode/scripts:/home/node/.opencode/bin:/home/node/.local/bin:/venv/bin:$PATH"' >> /home/node/.profile \
 && echo 'export PATH="/opt/opencode/scripts:/home/node/.opencode/bin:/home/node/.local/bin:/venv/bin:$PATH"' >> /home/node/.bashrc

# ---------- 11. Runtime ----------
# NOTE: entrypoint.sh starts as root (UID/GID remap + chown of named volumes)
# and drops to `node` via runuser before exec'ing opencode.
WORKDIR /workspace

# opencode web listens on 4096 by default.
EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/opencode/scripts/entrypoint.sh"]
