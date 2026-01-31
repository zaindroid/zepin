#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Pull Latest Config & Restart
#
# Run on any device to pull the latest repo changes and optionally
# restart the DePIN workload with updated config.
#
# Usage:
#   ./update.sh              # pull only
#   sudo ./update.sh restart # pull + restart containers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

ACTION="${1:-pull}"

# ─── Pull Latest ────────────────────────────────────────────────────────────
log_info "Pulling latest changes from origin..."
cd "$SCRIPT_DIR"
git pull --ff-only origin main
log_ok "Repo updated."

# ─── Restart if Requested ──────────────────────────────────────────────────
if [[ "$ACTION" == "restart" ]]; then
  require_root

  HOSTNAME=$(get_hostname)
  log_info "Restarting containers on ${HOSTNAME}..."

  case "$HOSTNAME" in
    depin-pi4)
      cd "${SCRIPT_DIR}/docker-compose/bandwidth-depin" 2>/dev/null && \
        docker compose down && docker compose up -d || log_warn "No bandwidth compose found"
      ;;
    depin-pi3-1)
      cd "${SCRIPT_DIR}/docker-compose/storage-depin" 2>/dev/null && \
        docker compose down && docker compose up -d || log_warn "No storage compose found"
      ;;
    depin-pi3-2)
      cd "${SCRIPT_DIR}/docker-compose/indexing-depin" 2>/dev/null && \
        docker compose down && docker compose up -d || log_warn "No indexing compose found"
      ;;
    depin-pi3-mon)
      cd "${SCRIPT_DIR}/docker-compose/monitoring" && \
        docker compose down && docker compose up -d
      ;;
    depin-jetson)
      cd "${SCRIPT_DIR}/docker-compose/compute-depin" 2>/dev/null && \
        docker compose down && docker compose up -d || log_warn "No compute compose found"
      ;;
    rtx-standby)
      log_info "RTX is standby only — nothing to restart."
      ;;
    *)
      log_warn "Unknown hostname '${HOSTNAME}'. No containers restarted."
      ;;
  esac

  echo ""
  docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
  log_ok "Restart complete."
fi
