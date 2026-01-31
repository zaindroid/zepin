#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 3: Docker Installation (All Nodes)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
check_internet

log_info "=== Docker Installation ==="

ARCH=$(get_arch)
log_info "Detected architecture: ${ARCH}"

# ─── Remove Old Docker Versions ─────────────────────────────────────────────
log_info "Removing old Docker packages (if any)..."
apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true
log_ok "Old packages removed."

# ─── Install Docker via Official Repo ───────────────────────────────────────
if ! command -v docker &>/dev/null; then
  log_info "Installing Docker CE..."

  # Add Docker GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add Docker repo
  echo \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  log_ok "Docker CE installed."
else
  log_ok "Docker already installed: $(docker --version)"
fi

# ─── Configure Docker Daemon ────────────────────────────────────────────────
log_info "Configuring Docker daemon..."

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 32768
    }
  },
  "no-new-privileges": true,
  "icc": false,
  "userland-proxy": false
}
EOF

log_ok "Docker daemon configured."

# ─── Start & Enable Docker ──────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
log_ok "Docker service started and enabled."

# ─── Add DePIN User to Docker Group ─────────────────────────────────────────
if id "$SSH_USER" &>/dev/null; then
  usermod -aG docker "$SSH_USER"
  log_ok "User '${SSH_USER}' added to docker group."
fi

# ─── Install Docker Compose (standalone, as fallback) ───────────────────────
if ! docker compose version &>/dev/null 2>&1; then
  log_info "Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin 2>/dev/null || {
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  }
  log_ok "Docker Compose installed."
else
  log_ok "Docker Compose already available: $(docker compose version)"
fi

# ─── Create Default DePIN Network ───────────────────────────────────────────
if ! docker network inspect "${DOCKER_NETWORK}" &>/dev/null 2>&1; then
  docker network create \
    --driver bridge \
    --subnet 172.28.0.0/16 \
    "${DOCKER_NETWORK}"
  log_ok "Docker network '${DOCKER_NETWORK}' created."
else
  log_ok "Docker network '${DOCKER_NETWORK}' already exists."
fi

# ─── Verify ─────────────────────────────────────────────────────────────────
log_info "=== Docker Installation Complete ==="
docker version --format '{{.Server.Version}}' | xargs -I {} log_info "Docker version: {}"
docker compose version 2>/dev/null | xargs -I {} log_info "{}"
docker info --format '{{.StorageDriver}}' | xargs -I {} log_info "Storage driver: {}"
log_ok "Phase 3 complete. Next: run 04-tailscale.sh"
