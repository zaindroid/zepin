#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Deploy / Redeploy DePIN Workload
#
# Use this AFTER setup.sh has already been run on this device.
# Deploys (or redeploys) only the DePIN workload for this device's role.
#
# Usage:
#   sudo ./deploy.sh              # auto-detect role from hostname
#   sudo ./deploy.sh bandwidth    # explicit role
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

require_root

# ─── Role Detection ────────────────────────────────────────────────────────

detect_role() {
  local hostname
  hostname=$(get_hostname)
  case "$hostname" in
    zpin-pi4)       echo "bandwidth"  ;;
    zpin-pi3-1)     echo "storage"    ;;
    zpin-pi3-2)     echo "indexing"   ;;
    zpin-pi3-mon)   echo "monitoring" ;;
    zpin-jetson)    echo "compute"    ;;
    bitbots01)      echo "rtx"        ;;
    *)              echo ""           ;;
  esac
}

ROLE="${1:-$(detect_role)}"

if [[ -z "$ROLE" ]]; then
  log_err "Cannot detect role from hostname '$(get_hostname)'."
  log_info "Usage: sudo ./deploy.sh <role>"
  log_info "Roles: bandwidth | storage | indexing | monitoring | compute | rtx"
  exit 1
fi

log_info "=== Deploying workload for role: ${ROLE} ==="

# ─── Pre-flight ─────────────────────────────────────────────────────────────

# Verify Docker is running
if ! docker info &>/dev/null 2>&1; then
  bail "Docker is not running. Run sudo ./setup.sh first."
fi

# Verify Tailscale
if ! tailscale status &>/dev/null 2>&1; then
  log_warn "Tailscale is not connected. Management plane will be unavailable."
fi

# ─── Deploy By Role ────────────────────────────────────────────────────────

case "$ROLE" in
  bandwidth)
    log_info "Deploying Bandwidth DePIN (zpin-pi4)..."
    bash "${SCRIPT_DIR}/scripts/08-deploy-bandwidth.sh"
    ;;

  storage)
    # Ensure disk is mounted
    if ! mountpoint -q /mnt/depin-storage 2>/dev/null; then
      log_info "Storage not mounted. Running disk prep first..."
      bash "${SCRIPT_DIR}/scripts/07-storage-prep.sh"
    fi
    log_info "Deploying Storage DePIN (zpin-pi3-1)..."
    bash "${SCRIPT_DIR}/scripts/09-deploy-storage.sh"
    ;;

  indexing)
    log_info "Deploying Indexing DePIN (zpin-pi3-2)..."
    bash "${SCRIPT_DIR}/scripts/10-deploy-indexing.sh"
    ;;

  monitoring)
    log_info "Deploying Monitoring Stack (zpin-pi3-mon)..."
    bash "${SCRIPT_DIR}/scripts/05-monitoring-node.sh"
    ;;

  compute)
    log_info "Deploying Compute DePIN (zpin-jetson)..."
    bash "${SCRIPT_DIR}/scripts/11-deploy-compute.sh"
    ;;

  rtx)
    log_info "RTX Standby — drivers and monitoring only..."
    bash "${SCRIPT_DIR}/scripts/12-rtx-standby.sh"
    ;;

  *)
    bail "Unknown role: ${ROLE}. Valid: bandwidth | storage | indexing | monitoring | compute | rtx"
    ;;
esac

echo ""
bash "${SCRIPT_DIR}/scripts/healthcheck.sh"
log_ok "Deployment complete for role: ${ROLE}"
