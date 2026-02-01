#!/usr/bin/env bash
# =============================================================================
# Storj Identity Fast Generation (RTX PC → Pi4 Transfer)
#
# USAGE:
#   Run this script on your laptop (zAiNeY) - it will:
#   1. SSH to bitbots01 (RTX PC) to generate identity quickly (~15-30 min)
#   2. Transfer the generated identity to zpin-pi4 over Tailscale
#   3. Set correct ownership/permissions on zpin-pi4
#
# WHY:
#   - RTX 3090 generates identity in 15-30 minutes
#   - Pi 4 would take 1-8 hours
#   - Identity is portable and only created once
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

# Target nodes
RTX_HOST="bitbots01"
PI4_HOST="zpin-pi4"
SSH_USER="zpin"

# Tailscale IPs (from 00-common.sh)
RTX_TS_IP="${TS_IPS[rtx]}"
PI4_TS_IP="${TS_IPS[pi4]}"

if [[ -z "$RTX_TS_IP" ]]; then
  bail "RTX Tailscale IP not set in 00-common.sh. Run Tailscale on bitbots01 first."
fi

if [[ -z "$PI4_TS_IP" ]]; then
  bail "Pi4 Tailscale IP not set in 00-common.sh. Run Tailscale on zpin-pi4 first."
fi

log_info "=== Storj Identity Fast Generation ==="
log_info "RTX PC: ${RTX_HOST} (${RTX_TS_IP})"
log_info "Target: ${PI4_HOST} (${PI4_TS_IP})"
echo ""

# ─── Step 1: Generate Identity on RTX PC ───────────────────────────────────
log_info "Step 1: Generating identity on ${RTX_HOST} (this takes 15-30 minutes)..."
log_warn "The RTX 3090 will be fully utilized during this time."
echo ""

ssh "${SSH_USER}@${RTX_TS_IP}" bash <<'REMOTE_SCRIPT'
set -euo pipefail

echo "[RTX] Starting identity generation..."

# Download identity binary for x86_64 (RTX is x86)
cd /tmp
curl -L https://github.com/storj/storj/releases/latest/download/identity_linux_amd64.zip -o identity_linux_amd64.zip
unzip -o identity_linux_amd64.zip
chmod +x identity

# Create identity
IDENTITY_DIR="/tmp/storj-identity-temp"
rm -rf "$IDENTITY_DIR"
mkdir -p "$IDENTITY_DIR"

echo "[RTX] Running identity creation at difficulty 36..."
echo "[RTX] Progress will be shown below. This is CPU-intensive."
./identity create storagenode --identity-dir "$IDENTITY_DIR"

# Verify creation
if [[ ! -f "${IDENTITY_DIR}/storagenode/identity.cert" ]]; then
  echo "[RTX ERROR] Identity creation failed!"
  exit 1
fi

echo "[RTX] Identity created successfully at ${IDENTITY_DIR}/storagenode"
ls -lh "${IDENTITY_DIR}/storagenode/"

# Cleanup binary
rm -f identity identity_linux_amd64.zip

echo "[RTX] Identity generation complete!"
REMOTE_SCRIPT

log_ok "Identity generated on ${RTX_HOST}."

# ─── Step 2: Transfer Identity to Pi4 ──────────────────────────────────────
log_info "Step 2: Transferring identity from ${RTX_HOST} to ${PI4_HOST}..."

# Create temp archive on RTX
ssh "${SSH_USER}@${RTX_TS_IP}" bash <<'REMOTE_TAR'
cd /tmp/storj-identity-temp
tar czf /tmp/storj-identity.tar.gz storagenode/
echo "[RTX] Identity packed into /tmp/storj-identity.tar.gz"
REMOTE_TAR

# Transfer via this laptop (relay)
TEMP_LOCAL="/tmp/storj-identity-$(date +%s).tar.gz"
log_info "Downloading from RTX to laptop..."
scp "${SSH_USER}@${RTX_TS_IP}:/tmp/storj-identity.tar.gz" "$TEMP_LOCAL"

log_info "Uploading from laptop to Pi4..."
scp "$TEMP_LOCAL" "${SSH_USER}@${PI4_TS_IP}:/tmp/storj-identity.tar.gz"

log_ok "Identity transferred to ${PI4_HOST}."

# ─── Step 3: Extract and Set Permissions on Pi4 ────────────────────────────
log_info "Step 3: Installing identity on ${PI4_HOST}..."

ssh "${SSH_USER}@${PI4_TS_IP}" sudo bash <<'REMOTE_INSTALL'
set -euo pipefail

IDENTITY_DIR="/mnt/depin-storage/identity"
mkdir -p "$IDENTITY_DIR"

cd "$IDENTITY_DIR"
tar xzf /tmp/storj-identity.tar.gz

# Verify
if [[ ! -f "${IDENTITY_DIR}/storagenode/identity.cert" ]]; then
  echo "[PI4 ERROR] Identity extraction failed!"
  exit 1
fi

# Set ownership
chown -R root:root "$IDENTITY_DIR"
chmod -R 700 "$IDENTITY_DIR"

echo "[PI4] Identity installed at ${IDENTITY_DIR}/storagenode"
ls -lh "${IDENTITY_DIR}/storagenode/"

# Cleanup
rm -f /tmp/storj-identity.tar.gz

echo "[PI4] Identity ready for Storj node deployment!"
REMOTE_INSTALL

log_ok "Identity installed on ${PI4_HOST}."

# ─── Step 4: Cleanup RTX ────────────────────────────────────────────────────
log_info "Step 4: Cleaning up temporary files on ${RTX_HOST}..."

ssh "${SSH_USER}@${RTX_TS_IP}" bash <<'REMOTE_CLEANUP'
rm -rf /tmp/storj-identity-temp /tmp/storj-identity.tar.gz
echo "[RTX] Cleanup complete."
REMOTE_CLEANUP

rm -f "$TEMP_LOCAL"

log_ok "Cleanup complete."

# ─── Done ───────────────────────────────────────────────────────────────────
echo ""
log_info "=== Identity Generation Complete ==="
log_ok "Storj identity successfully created and transferred!"
echo ""
log_info "Next steps on ${PI4_HOST}:"
log_info "  1. Edit docker-compose/storage-depin/.env with your wallet/email"
log_info "  2. Run: sudo bash scripts/09-deploy-storage.sh"
log_info "  3. Identity will be detected and used automatically"
echo ""
log_warn "IMPORTANT: Identity is now at /mnt/depin-storage/identity/storagenode on ${PI4_HOST}"
log_warn "NEVER delete this directory - it cannot be regenerated!"
