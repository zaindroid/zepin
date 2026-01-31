#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 11: Compute DePIN (depin-jetson ONLY)
# Deploy ONE compute/inference DePIN on Jetson Nano (2 GB).
# Must be event-driven: idle when no jobs, burst on demand.
#
# Suitable DePINs:
#   - io.net worker, Nosana node, Render worker, Akash provider (light), etc.
#   - Must support NVIDIA GPU (Maxwell arch on Jetson Nano)
#   - Must be event-driven (no constant GPU usage)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/compute-depin"

log_info "=== Deploying Compute DePIN on $(get_hostname) ==="

# ─── Verify Node ───────────────────────────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "depin-jetson" ]]; then
  log_warn "Expected 'depin-jetson', got '${CURRENT_HOST}'."
  confirm "Continue anyway?" || bail "Aborting."
fi

# ─── Verify NVIDIA Runtime ────────────────────────────────────────────────
log_info "Checking NVIDIA GPU and runtime..."

if ! command -v nvidia-smi &>/dev/null; then
  log_warn "nvidia-smi not found. CUDA toolkit may not be installed."
  log_info "On Jetson, install via JetPack SDK. For desktop, install nvidia-driver."
fi

# Check if nvidia-container-runtime is available
if docker info 2>/dev/null | grep -qi nvidia; then
  log_ok "NVIDIA Docker runtime detected."
else
  log_warn "NVIDIA Docker runtime not detected."
  log_info "Install nvidia-container-toolkit:"
  log_info "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
  log_info "On Jetson with JetPack, the runtime is usually pre-installed."
fi

# Show GPU info if available
nvidia-smi 2>/dev/null || tegrastats --interval 1000 --count 1 2>/dev/null || true

# ─── Generate Docker Compose ───────────────────────────────────────────────
cat > "${COMPOSE_DIR}/docker-compose.yml" <<'EOF'
# =============================================================================
# Compute DePIN — depin-jetson (Jetson Nano 2 GB)
# Event-driven: idle when no jobs, GPU burst only on demand.
# Replace image/config with your chosen compute DePIN.
# =============================================================================
services:
  compute-depin:
    image: YOUR_COMPUTE_DEPIN_IMAGE:latest    # <-- REPLACE
    container_name: compute-depin
    restart: unless-stopped
    runtime: nvidia                            # Use NVIDIA runtime
    environment:
      # Add your DePIN-specific env vars:
      # - WORKER_ID=your-worker-id
      # - MODE=event-driven
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      - TZ=UTC
    volumes:
      - compute-data:/data
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
          memory: 1024M
        reservations:
          memory: 256M
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
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

networks:
  depin-net:
    external: true

volumes:
  compute-data:
EOF

log_info "Docker Compose template created at ${COMPOSE_DIR}/docker-compose.yml"
log_warn ">>> EDIT the compose file with your chosen compute DePIN image and config <<<"

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
log_info "Total RAM: ${TOTAL_MEM} MB"

if (( TOTAL_MEM < 1800 )); then
  log_warn "Jetson Nano 2 GB detected. 1 GB container limit is strict."
  log_warn "Choose a compute DePIN with minimal idle memory footprint."
fi

if ! docker network inspect depin-net &>/dev/null; then
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Deploy ─────────────────────────────────────────────────────────────────
if grep -q "YOUR_COMPUTE_DEPIN_IMAGE" "${COMPOSE_DIR}/docker-compose.yml"; then
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

# ─── Verify Idle Behavior ──────────────────────────────────────────────────
log_info "Verifying GPU is idle when no jobs..."
sleep 10
if command -v nvidia-smi &>/dev/null; then
  GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [[ -n "$GPU_UTIL" ]] && (( GPU_UTIL > 10 )); then
    log_warn "GPU utilization is ${GPU_UTIL}% — should be near 0% when idle."
  else
    log_ok "GPU utilization: ${GPU_UTIL:-0}% (idle)"
  fi
fi

validate_no_inbound

log_info "=== Compute DePIN Deployment Complete ==="
log_ok "Phase 11 complete. Verify idle behavior over 24 hours."
