#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 9: Storage DePIN (zpin-pi3-1 ONLY)
# Deploy ONE storage/data-availability DePIN on the node with 500 GB USB.
#
# TEMPLATE: Replace the Docker image and config with your chosen DePIN.
# Suitable storage DePINs for RPi 3B+ with USB storage:
#   - Filecoin (light/relay mode), Storj, Crust, etc.
#   - Must support outbound-only or lightweight relay mode
#   - Must NOT require public IP or inbound ports
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/storage-depin"

log_info "=== Deploying Storage DePIN on $(get_hostname) ==="

# ─── Verify Node ───────────────────────────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "zpin-pi3-1" ]]; then
  log_warn "Expected 'zpin-pi3-1', got '${CURRENT_HOST}'."
  confirm "Continue anyway?" || bail "Aborting."
fi

# ─── Verify Storage Mount ─────────────────────────────────────────────────
if ! mountpoint -q "$STORAGE_MOUNT"; then
  bail "Storage not mounted at ${STORAGE_MOUNT}. Run 07-storage-prep.sh first."
fi

AVAIL_GB=$(df -BG "$STORAGE_MOUNT" | awk 'NR==2 {print $4}' | tr -d 'G')
log_info "Storage available: ${AVAIL_GB} GB at ${STORAGE_MOUNT}"

if (( AVAIL_GB < 50 )); then
  bail "Less than 50 GB available. Not enough for storage DePIN."
fi

# ─── Generate Docker Compose ───────────────────────────────────────────────
cat > "${COMPOSE_DIR}/docker-compose.yml" <<EOF
# =============================================================================
# Storage DePIN — zpin-pi3-1 (500 GB USB)
# Replace image/config with your chosen storage DePIN.
# =============================================================================
services:
  storage-depin:
    image: YOUR_STORAGE_DEPIN_IMAGE:latest    # <-- REPLACE
    container_name: storage-depin
    restart: unless-stopped
    environment:
      # Add your DePIN-specific env vars:
      # - WALLET_ADDRESS=your-address
      # - NODE_ID=your-node-id
      - TZ=UTC
    volumes:
      - ${STORAGE_MOUNT}/data:/data           # DePIN data on USB drive
      - storage-config:/config                # Config persisted separately
    networks:
      - depin-net
    # IMPORTANT: No ports exposed — outbound only
    dns:
      - 1.1.1.1
      - 8.8.8.8
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 512M
        reservations:
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f 'depin' || exit 1"]  # <-- adjust
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s
    security_opt:
      - no-new-privileges:true

networks:
  depin-net:
    external: true

volumes:
  storage-config:
EOF

log_info "Docker Compose template created at ${COMPOSE_DIR}/docker-compose.yml"
log_warn ">>> EDIT the compose file with your chosen storage DePIN image and config <<<"

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
log_info "Running pre-flight checks..."

TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
AVAIL_MEM=$(free -m | awk '/^Mem:/ {print $7}')
log_info "Total RAM: ${TOTAL_MEM} MB, Available: ${AVAIL_MEM} MB"

# RPi 3B+ has only 1 GB RAM — 512 MB limit is tight
if (( TOTAL_MEM < 900 )); then
  log_warn "RPi 3B+ detected (${TOTAL_MEM} MB RAM). 512 MB container limit is strict."
  log_warn "Choose a storage DePIN with minimal RAM footprint."
fi

# Verify storage health
if command -v depin-storage-health &>/dev/null; then
  depin-storage-health
fi

# Docker network
if ! docker network inspect depin-net &>/dev/null; then
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Deploy ─────────────────────────────────────────────────────────────────
if grep -q "YOUR_STORAGE_DEPIN_IMAGE" "${COMPOSE_DIR}/docker-compose.yml"; then
  log_warn "Docker Compose still has placeholder image."
  log_warn "Edit ${COMPOSE_DIR}/docker-compose.yml first, then run:"
  log_info "  cd ${COMPOSE_DIR} && docker compose up -d"
  exit 0
fi

log_info "Deploying..."
cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d

sleep 15
docker compose ps
docker compose logs --tail=20

validate_no_inbound

log_info "=== Storage DePIN Deployment Complete ==="
log_info "Data directory: ${STORAGE_MOUNT}/data"
log_ok "Phase 9 complete."
