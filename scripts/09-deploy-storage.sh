#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 9: Storage DePIN Deployment
# Deploys Storj storage node in dorm-safe, outbound-only mode.
#
# DORM-SAFE CONFIGURATION:
#   - Outbound-only (no inbound ports required)
#   - Encrypted data chunks (no content liability)
#   - Limited bandwidth allocation
#   - Strict resource limits (CPU/RAM)
#
# NOTE: Storj can work without port forwarding, but earnings will be lower.
# This is acceptable for dorm-safe operation.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/storage-depin"

log_info "=== Deploying Storj Storage Node on $(get_hostname) ==="

# ─── Verify Storage Mount ─────────────────────────────────────────────────
if ! mountpoint -q "$STORAGE_MOUNT"; then
  bail "Storage not mounted at ${STORAGE_MOUNT}. Run 07-storage-prep.sh first."
fi

AVAIL_GB=$(df -BG "$STORAGE_MOUNT" | awk 'NR==2 {print $4}' | tr -d 'G')
log_info "Storage available: ${AVAIL_GB} GB at ${STORAGE_MOUNT}"

if (( AVAIL_GB < 50 )); then
  bail "Less than 50 GB available. Not enough for Storj (minimum 550 GB recommended)."
fi

# ─── Storj Configuration ──────────────────────────────────────────────────
log_warn "=== Storj Setup Required ==="
log_warn "Before deploying, you need:"
log_warn "  1. Storj account: https://www.storj.io/host-a-node"
log_warn "  2. Auth token from Storj dashboard"
log_warn "  3. Wallet address (ERC-20 compatible)"
log_warn "  4. Email address"
echo ""

if [[ ! -f "${COMPOSE_DIR}/.env" ]]; then
  log_info "Creating .env template at ${COMPOSE_DIR}/.env"
  cat > "${COMPOSE_DIR}/.env" <<'EOF'
# Storj Storage Node Configuration
# Fill in your details before deploying

# Get this from: https://registration.storj.io/
STORJ_WALLET=0xYOUR_WALLET_ADDRESS_HERE

# Get auth token from Storj dashboard
STORJ_EMAIL=your-email@example.com

# Storage allocation (70% of available space)
STORJ_STORAGE=300GB

# Bandwidth allocation (conservative for dorm)
# Default: 2TB/month, we limit to 500GB/month for safety
STORJ_BANDWIDTH=500GB
EOF
  log_warn ">>> EDIT ${COMPOSE_DIR}/.env with your Storj credentials <<<"
  log_info "Then re-run this script."
  exit 0
fi

# Load config
set -a
source "${COMPOSE_DIR}/.env"
set +a

if [[ "$STORJ_WALLET" == "0xYOUR_WALLET_ADDRESS_HERE" ]]; then
  bail "Please edit ${COMPOSE_DIR}/.env with your actual Storj wallet address."
fi

# ─── Generate Docker Compose ───────────────────────────────────────────────
log_info "Generating Storj docker-compose.yml..."

cat > "${COMPOSE_DIR}/docker-compose.yml" <<EOF
# =============================================================================
# Storj Storage Node — Dorm-Safe Configuration
#
# SAFETY FEATURES:
#   - No inbound ports exposed (works in CGNAT/NAT)
#   - Encrypted chunks only (no content liability)
#   - Bandwidth limited to ${STORJ_BANDWIDTH}/month
#   - CPU capped at 50%, RAM limited to 512MB
#   - Outbound HTTPS traffic only
#
# TRADE-OFFS:
#   - Lower earnings without port forwarding (~30-50% of full node)
#   - Acceptable for dorm-safe, low-risk operation
# =============================================================================
services:
  storj:
    image: storjlabs/storagenode:latest
    container_name: storj-storage
    restart: unless-stopped
    environment:
      WALLET: ${STORJ_WALLET}
      EMAIL: ${STORJ_EMAIL}
      ADDRESS: ""  # Empty = outbound-only mode, no public IP required
      STORAGE: ${STORJ_STORAGE}
      # Bandwidth limits (dorm-safe)
      STORAGE2_BANDWIDTH_ALLOCATION: ${STORJ_BANDWIDTH}
      # Logging
      LOG_LEVEL: info
    volumes:
      - ${STORAGE_MOUNT}/storj-data:/app/config
      - ${STORAGE_MOUNT}/storj-identity/storagenode:/app/identity
    networks:
      - depin-net
    # CRITICAL: No ports exposed - outbound only
    # ports: [] # Explicitly no ports
    dns:
      - 1.1.1.1
      - 8.8.8.8
    deploy:
      resources:
        limits:
          cpus: "0.50"  # 50% CPU cap
          memory: 512M
        reservations:
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q http://localhost:14002/api/sno || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s
    security_opt:
      - no-new-privileges:true

networks:
  depin-net:
    external: true
EOF

log_ok "Docker Compose generated."

# ─── Identity Generation ──────────────────────────────────────────────────
IDENTITY_DIR="${STORAGE_MOUNT}/storj-identity"

if [[ ! -f "${IDENTITY_DIR}/storagenode/identity.key" ]]; then
  log_info "Generating Storj identity (this may take a while)..."
  log_warn "You need to authorize this identity in the Storj dashboard before it works!"

  mkdir -p "$IDENTITY_DIR"

  # Generate identity using Storj's setup command
  # The modern storagenode image uses 'storagenode setup' to generate identity
  mkdir -p "${IDENTITY_DIR}/storagenode"
  docker run --rm \
    -v "${IDENTITY_DIR}/storagenode:/app/identity" \
    --user "$(id -u):$(id -g)" \
    storjlabs/storagenode:latest \
    setup --identity-dir /app/identity

  log_ok "Identity generated at ${IDENTITY_DIR}/storagenode"
  log_warn ">>> Sign this identity at https://registration.storj.io/ <<<"
  log_info "You'll need the node ID from ${IDENTITY_DIR}/storagenode/identity.cert"
fi

# ─── Pre-flight Checks ─────────────────────────────────────────────────────
log_info "Running pre-flight checks..."

TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
AVAIL_MEM=$(free -m | awk '/^Mem:/ {print $7}')
log_info "Total RAM: ${TOTAL_MEM} MB, Available: ${AVAIL_MEM} MB"

# Docker network
if ! docker network inspect depin-net &>/dev/null; then
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Deploy ─────────────────────────────────────────────────────────────────
log_info "Deploying Storj storage node..."
cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d

sleep 20
docker compose ps
docker compose logs --tail=30

validate_no_inbound

log_info "=== Storj Storage Node Deployed ==="
log_info "Data directory: ${STORAGE_MOUNT}/storj-data"
log_info "Identity: ${STORAGE_MOUNT}/storj-identity"
log_info "Bandwidth limit: ${STORJ_BANDWIDTH}/month (dorm-safe)"
log_info ""
log_warn "IMPORTANT: Monitor bandwidth usage in first 72 hours"
log_warn "If network admin flags high traffic, reduce STORJ_BANDWIDTH in .env"
log_ok "Phase 9 complete."
