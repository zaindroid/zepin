#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 9: Storj Storage Node Deployment
# Corrected deployment following proper Storj architecture
#
# ARCHITECTURE:
#   1. Identity created ONCE on host (never regenerated)
#   2. Container mounts identity as read-only
#   3. Authorization done via Storj website (one-time)
#
# DORM REALITY:
#   - Will run, but earnings limited without port forwarding
#   - Vetting period: 1-6 months before significant earnings
#   - Uptime history matters more than instant earnings
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/storage-depin"
IDENTITY_DIR="/mnt/depin-storage/identity"
CONFIG_DIR="/mnt/depin-storage/config"
STORAGE_DIR="/mnt/depin-storage/storage"

log_info "=== Storj Storage Node Deployment on $(get_hostname) ==="

# ─── Verify Storage Mount ─────────────────────────────────────────────────
if ! mountpoint -q "$STORAGE_MOUNT"; then
  bail "Storage not mounted at ${STORAGE_MOUNT}. Run 07-storage-prep.sh first."
fi

AVAIL_GB=$(df -BG "$STORAGE_MOUNT" | awk 'NR==2 {print $4}' | tr -d 'G')
log_info "Storage available: ${AVAIL_GB} GB at ${STORAGE_MOUNT}"

if (( AVAIL_GB < 100 )); then
  bail "Less than 100 GB available. Storj requires minimum 550 GB recommended."
fi

# ─── Configuration ──────────────────────────────────────────────────────────
log_warn "=== Storj Setup Required ==="
log_warn "You need:"
log_warn "  1. ERC-20 wallet address (MetaMask, etc.)"
log_warn "  2. Email address"
log_warn "  3. Authorization at https://registration.storj.io/ (AFTER identity creation)"
echo ""

if [[ ! -f "${COMPOSE_DIR}/.env" ]]; then
  log_info "Creating .env template..."
  mkdir -p "$COMPOSE_DIR"
  cat > "${COMPOSE_DIR}/.env" <<'EOF'
# Storj Storage Node Configuration
STORJ_WALLET=0xYOUR_WALLET_ADDRESS_HERE
STORJ_EMAIL=your-email@example.com
STORJ_STORAGE=400GB
EOF
  log_warn ">>> EDIT ${COMPOSE_DIR}/.env with your wallet and email <<<"
  log_info "Then re-run this script."
  exit 0
fi

# Load config
set -a
source "${COMPOSE_DIR}/.env"
set +a

if [[ "$STORJ_WALLET" == "0xYOUR_WALLET_ADDRESS_HERE" ]]; then
  bail "Please edit ${COMPOSE_DIR}/.env with your actual wallet address."
fi

# ─── Step 1: Prepare Directories ───────────────────────────────────────────
log_info "Step 1: Preparing directories..."
mkdir -p "$IDENTITY_DIR" "$CONFIG_DIR" "$STORAGE_DIR"
log_ok "Directories created."

# ─── Step 2: Create Identity (CRITICAL) ────────────────────────────────────
if [[ ! -f "${IDENTITY_DIR}/storagenode/identity.cert" ]]; then
  log_warn "=== Identity Not Found ==="
  log_warn "Storj requires a cryptographic identity (difficulty 36 proof-of-work)."
  log_warn "Generation time:"
  log_warn "  - On this Pi 4: 1-8 hours"
  log_warn "  - On RTX 3090:  15-30 minutes"
  echo ""
  log_info "RECOMMENDED: Generate on RTX PC (bitbots01) and transfer here."
  log_info "Run this command on your laptop (zAiNeY):"
  log_info "  bash scripts/storj-identity-fast-gen.sh"
  echo ""
  confirm "Generate identity on THIS Pi (slow, 1-8 hours)?" || bail "Aborted. Use storj-identity-fast-gen.sh instead."

  # Download identity binary for ARM64
  log_info "Downloading identity binary..."
  cd /tmp
  curl -L https://github.com/storj/storj/releases/latest/download/identity_linux_arm64.zip -o identity_linux_arm64.zip
  unzip -o identity_linux_arm64.zip
  chmod +x identity

  # Create identity using the binary
  log_info "Creating identity (difficulty 36)... This will take 1-8 hours."
  log_info "Progress will be shown below. Do NOT interrupt!"
  log_warn "You can run this in screen/tmux and detach if needed."

  # Run identity creation with output directory
  IDENTITY_TEMP="/tmp/storj-identity"
  mkdir -p "$IDENTITY_TEMP"
  ./identity create storagenode --identity-dir "$IDENTITY_TEMP"

  # Move generated identity to correct location
  mkdir -p "$IDENTITY_DIR"
  mv "$IDENTITY_TEMP/storagenode" "$IDENTITY_DIR/"
  rm -rf "$IDENTITY_TEMP"
  rm -f identity identity_linux_arm64.zip

  if [[ ! -f "${IDENTITY_DIR}/storagenode/identity.cert" ]]; then
    bail "Identity creation failed. Check output above."
  fi

  log_ok "Identity created at ${IDENTITY_DIR}/storagenode"

  # Show Node ID
  log_info "Your Node ID (save this):"
  cat "${IDENTITY_DIR}/storagenode/identity.cert" | grep -i "node id" || \
    echo "Check ${IDENTITY_DIR}/storagenode/identity.cert for Node ID"

  echo ""
  log_info "=== Identity Ready ==="
  log_info "Authorization is no longer required - your identity can be used directly."
  log_info "The node will start earning after a vetting period (1-6 months)."
  echo ""
  confirm "Continue with deployment?" || exit 0
else
  log_ok "Identity already exists at ${IDENTITY_DIR}/storagenode"
fi

# ─── Step 3: Generate Docker Compose ───────────────────────────────────────
log_info "Step 3: Generating docker-compose.yml..."

cat > "${COMPOSE_DIR}/docker-compose.yml" <<EOF
# =============================================================================
# Storj Storage Node — Correct Configuration
#
# EARNINGS REALITY:
#   - First 1-2 months: \$0-2 (vetting period)
#   - After vetting: \$3-8/month
#   - With good uptime & network: \$10-30/month
#   - Long-term (TB+ storage): \$40+/month
#
# DORM MODE:
#   - Ports exposed for maximum earnings potential
#   - If dorm blocks ports, node still runs but earns less
#   - Uptime history matters more than instant earnings
# =============================================================================
services:
  storj:
    image: storjlabs/storagenode:latest
    container_name: storj-storage
    restart: unless-stopped

    environment:
      WALLET: ${STORJ_WALLET}
      EMAIL: ${STORJ_EMAIL}
      ADDRESS: ":28967"
      STORAGE: ${STORJ_STORAGE}
      BANDWIDTH: "0"  # 0 = unlimited (Storj rate-limits automatically)
      LOG_LEVEL: info

    volumes:
      # Identity: read-only, created once on host
      - ${IDENTITY_DIR}/storagenode:/app/identity:ro
      # Storage: Storj manages config and data under this directory
      - ${STORAGE_DIR}:/app/config

    ports:
      # Storage node communication (required for earnings)
      # If dorm blocks these, node still works but earns 30-50% less
      - "28967:28967/tcp"
      - "28967:28967/udp"
      # Dashboard (web UI) - only accessible on local network
      - "14002:14002"

    networks:
      - depin-net

    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 1024M
        reservations:
          memory: 256M

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

log_ok "docker-compose.yml generated."

# ─── Step 4: Pre-flight Checks ─────────────────────────────────────────────
log_info "Step 4: Running pre-flight checks..."

TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
log_info "Total RAM: ${TOTAL_MEM} MB"

if ! docker network inspect depin-net &>/dev/null; then
  docker network create --driver bridge --subnet 172.28.0.0/16 depin-net
fi

# ─── Step 5: Deploy ─────────────────────────────────────────────────────────
log_info "Step 5: Deploying Storj storage node..."

# Clean up any previous failed deployment
cd "$COMPOSE_DIR"
docker compose down 2>/dev/null || true
docker rm -f storj-storage 2>/dev/null || true

# Start node
docker compose pull
docker compose up -d

sleep 10
docker compose ps
echo ""
docker compose logs --tail=50

echo ""
log_info "=== Storj Storage Node Deployed ==="
log_info "Identity: ${IDENTITY_DIR}/storagenode"
log_info "Storage allocation: ${STORJ_STORAGE}"
log_info ""
log_info "Dashboard: http://$(hostname -I | awk '{print $1}'):14002"
log_info "  (or via Tailscale: http://$(get_tailscale_ip):14002)"
log_info ""
log_warn "IMPORTANT NEXT STEPS:"
log_warn "  1. Monitor logs: docker logs -f storj-storage"
log_warn "  2. Check dashboard for satellite connections"
log_warn "  3. Wait for vetting period (1-6 months for significant earnings)"
log_warn "  4. NEVER delete ${IDENTITY_DIR} - identity is permanent"
echo ""
log_ok "Phase 9 complete."
