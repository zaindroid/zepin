#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 8: Bandwidth DePIN (depin-pi4 ONLY)
# Deploy ONE bandwidth/relay DePIN. Outbound-only. No inbound ports.
#
# TEMPLATE: Replace the Docker image and config with your chosen DePIN.
# Suitable DePINs for bandwidth on RPi 4:
#   - Grass, Honeygain, Repocket, EarnApp, PacketStream, etc.
#   - Must be outbound-only (HTTPS/WSS)
#   - Must NOT require inbound ports
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/bandwidth-depin"
mkdir -p "$COMPOSE_DIR"

log_info "=== Deploying Bandwidth DePIN on $(get_hostname) ==="

# ─── Verify Node ───────────────────────────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "depin-pi4" ]]; then
  log_warn "Expected 'depin-pi4', got '${CURRENT_HOST}'."
  confirm "Continue anyway?" || bail "Aborting."
fi

# ─── Generate Docker Compose ───────────────────────────────────────────────
# >>> CUSTOMIZE THIS SECTION FOR YOUR CHOSEN BANDWIDTH DePIN <<<

cat > "${COMPOSE_DIR}/docker-compose.yml" <<'EOF'
# =============================================================================
# Bandwidth DePIN — depin-pi4
# Replace image/config with your chosen bandwidth DePIN.
#
# Example structure for a typical bandwidth-sharing DePIN:
# =============================================================================
services:
  bandwidth-depin:
    image: YOUR_DEPIN_IMAGE:latest          # <-- REPLACE
    container_name: bandwidth-depin
    restart: unless-stopped
    environment:
      # Add your DePIN-specific env vars here:
      # - DEVICE_ID=your-device-id
      # - AUTH_TOKEN=your-auth-token
      - TZ=UTC
    # volumes:
    #   - bandwidth-data:/data              # <-- if needed
    networks:
      - depin-net
    # IMPORTANT: No ports exposed — outbound only
    # ports: []                             # <-- DO NOT add ports
    dns:
      - 1.1.1.1
      - 8.8.8.8
    deploy:
      resources:
        limits:
          cpus: "0.60"
          memory: 1536M
        reservations:
          memory: 256M
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
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp:size=64M

networks:
  depin-net:
    external: true

# volumes:
#   bandwidth-data:
EOF

log_info "Docker Compose template created at ${COMPOSE_DIR}/docker-compose.yml"
log_warn ">>> EDIT the compose file with your chosen DePIN image and config <<<"

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
log_info "Running pre-flight checks..."

# Check system resources
TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
AVAIL_MEM=$(free -m | awk '/^Mem:/ {print $7}')
log_info "Total RAM: ${TOTAL_MEM} MB, Available: ${AVAIL_MEM} MB"

if (( AVAIL_MEM < 512 )); then
  log_warn "Available memory is low (${AVAIL_MEM} MB). DePIN may struggle."
fi

CPU_CORES=$(nproc)
log_info "CPU cores: ${CPU_CORES}"

# Check Docker network exists
if ! docker network inspect depin-net &>/dev/null; then
  log_info "Creating depin-net Docker network..."
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Deploy (only if user has customized) ──────────────────────────────────
if grep -q "YOUR_DEPIN_IMAGE" "${COMPOSE_DIR}/docker-compose.yml"; then
  log_warn "Docker Compose still has placeholder image."
  log_warn "Edit ${COMPOSE_DIR}/docker-compose.yml first, then run:"
  log_info "  cd ${COMPOSE_DIR} && docker compose up -d"
  exit 0
fi

log_info "Deploying..."
cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d

sleep 10
docker compose ps
docker compose logs --tail=20

# ─── Validate No Inbound ──────────────────────────────────────────────────
validate_no_inbound

log_info "=== Bandwidth DePIN Deployment Complete ==="
log_ok "Phase 8 complete. Monitor via Grafana for 72 hours before deploying more."
