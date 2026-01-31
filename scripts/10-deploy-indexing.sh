#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 10: Indexing DePIN (depin-pi3-2 ONLY)
# Deploy ONE lightweight indexing / helper DePIN.
# Use pruned/light modes only. Outbound-only.
#
# Suitable DePINs:
#   - The Graph (indexer light mode), Subsquid worker, etc.
#   - Must support light/pruned operation
#   - Must NOT require inbound ports
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/indexing-depin"

log_info "=== Deploying Indexing DePIN on $(get_hostname) ==="

# ─── Verify Node ───────────────────────────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "depin-pi3-2" ]]; then
  log_warn "Expected 'depin-pi3-2', got '${CURRENT_HOST}'."
  confirm "Continue anyway?" || bail "Aborting."
fi

# ─── Generate Docker Compose ───────────────────────────────────────────────
cat > "${COMPOSE_DIR}/docker-compose.yml" <<'EOF'
# =============================================================================
# Indexing DePIN — depin-pi3-2
# Replace image/config with your chosen indexing DePIN.
# Must use light/pruned mode — RPi 3B+ has only 1 GB RAM.
# =============================================================================
services:
  indexing-depin:
    image: YOUR_INDEXING_DEPIN_IMAGE:latest    # <-- REPLACE
    container_name: indexing-depin
    restart: unless-stopped
    environment:
      # Add your DePIN-specific env vars:
      # - MODE=light
      # - PRUNED=true
      - TZ=UTC
    volumes:
      - indexing-data:/data
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
  indexing-data:
EOF

log_info "Docker Compose template created at ${COMPOSE_DIR}/docker-compose.yml"
log_warn ">>> EDIT the compose file with your chosen indexing DePIN image and config <<<"

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
AVAIL_MEM=$(free -m | awk '/^Mem:/ {print $7}')
log_info "Total RAM: ${TOTAL_MEM} MB, Available: ${AVAIL_MEM} MB"

if (( TOTAL_MEM < 900 )); then
  log_warn "RPi 3B+ detected. Use ONLY light/pruned indexing modes."
fi

if ! docker network inspect depin-net &>/dev/null; then
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Deploy ─────────────────────────────────────────────────────────────────
if grep -q "YOUR_INDEXING_DEPIN_IMAGE" "${COMPOSE_DIR}/docker-compose.yml"; then
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

validate_no_inbound

log_info "=== Indexing DePIN Deployment Complete ==="
log_ok "Phase 10 complete."
