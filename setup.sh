#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Device Setup Entry Point
#
# Clone this repo on any device and run:
#   sudo ./setup.sh
#
# It will ask which role this device plays, then run every phase needed
# for that specific device — in order, with validation between steps.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

require_root

# ─── Role Selection ─────────────────────────────────────────────────────────

print_banner() {
  echo ""
  echo "============================================================"
  echo "  DePIN Edge Cluster — Device Setup"
  echo "============================================================"
  echo ""
  echo "  Available roles:"
  echo ""
  echo "    1) bandwidth    — zpin-pi4         (RPi 4, bandwidth DePIN)"
  echo "    2) storage      — zpin-pi3-1       (RPi 3B+ + 500 GB USB, storage DePIN)"
  echo "    3) indexing     — zpin-pi3-2       (RPi 3B+ , indexing DePIN)"
  echo "    4) monitoring   — TBD              (RPi 3B+ , Prometheus + Grafana)"
  echo "    5) compute      — TBD              (Jetson Nano, compute DePIN)"
  echo "    6) rtx          — bitbots01        (RTX 3090 PC, standby only)"
  echo ""
}

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

ROLE="${1:-}"

if [[ -z "$ROLE" ]]; then
  # Try auto-detect from hostname
  DETECTED=$(detect_role)
  if [[ -n "$DETECTED" ]]; then
    log_info "Auto-detected role from hostname: ${DETECTED}"
    confirm "Use role '${DETECTED}'?" && ROLE="$DETECTED"
  fi
fi

if [[ -z "$ROLE" ]]; then
  print_banner
  read -rp "Select role (1-6 or name): " CHOICE
  case "$CHOICE" in
    1|bandwidth)   ROLE="bandwidth"  ;;
    2|storage)     ROLE="storage"    ;;
    3|indexing)    ROLE="indexing"    ;;
    4|monitoring)  ROLE="monitoring" ;;
    5|compute)     ROLE="compute"    ;;
    6|rtx)         ROLE="rtx"        ;;
    *) bail "Invalid choice: ${CHOICE}" ;;
  esac
fi

# Map role → node key and hostname
declare -A ROLE_TO_KEY=(
  [bandwidth]="pi4"
  [storage]="pi3-1"
  [indexing]="pi3-2"
  [monitoring]="pi3-mon"
  [compute]="jetson"
  [rtx]="rtx"
)

NODE_KEY="${ROLE_TO_KEY[$ROLE]:-}"
[[ -n "$NODE_KEY" ]] || bail "Unknown role: $ROLE"
TARGET_HOSTNAME="${NODES[$NODE_KEY]}"

echo ""
log_info "============================================================"
log_info "  Role:     ${ROLE}"
log_info "  Hostname: ${TARGET_HOSTNAME}"
log_info "  Node key: ${NODE_KEY}"
log_info "============================================================"
echo ""
confirm "Proceed with full setup for '${ROLE}'?" || bail "Aborted."

# ─── Phase Execution Helper ────────────────────────────────────────────────

run_phase() {
  local phase_num="$1"
  local phase_name="$2"
  local script="$3"
  shift 3
  local args=("$@")

  echo ""
  log_info "──────────────────────────────────────────────────────────"
  log_info "  Phase ${phase_num}: ${phase_name}"
  log_info "──────────────────────────────────────────────────────────"
  echo ""

  if [[ ! -f "$script" ]]; then
    bail "Script not found: $script"
  fi

  bash "$script" "${args[@]}"

  log_ok "Phase ${phase_num} complete."
  echo ""
}

# ─── Run Phases For Role ───────────────────────────────────────────────────

# Phases 1-4 are common to ALL nodes
run_phase 1 "Base OS Setup"        "${SCRIPT_DIR}/scripts/01-base-setup.sh" "$NODE_KEY"
run_phase 2 "Security Hardening"   "${SCRIPT_DIR}/scripts/02-security.sh"
run_phase 3 "Docker Installation"  "${SCRIPT_DIR}/scripts/03-docker-install.sh"
run_phase 4 "Tailscale Enrollment" "${SCRIPT_DIR}/scripts/04-tailscale.sh"

# Phase 5+: role-specific
case "$ROLE" in
  monitoring)
    run_phase 5 "Node Exporter"        "${SCRIPT_DIR}/scripts/06-node-exporter.sh"
    run_phase 6 "Monitoring Stack"     "${SCRIPT_DIR}/scripts/05-monitoring-node.sh"
    ;;

  bandwidth)
    run_phase 5 "Node Exporter"        "${SCRIPT_DIR}/scripts/06-node-exporter.sh"
    run_phase 6 "Bandwidth DePIN"      "${SCRIPT_DIR}/scripts/08-deploy-bandwidth.sh"
    ;;

  storage)
    run_phase 5 "Node Exporter"        "${SCRIPT_DIR}/scripts/06-node-exporter.sh"
    run_phase 6 "Storage Disk Prep"    "${SCRIPT_DIR}/scripts/07-storage-prep.sh"
    run_phase 7 "Storage DePIN"        "${SCRIPT_DIR}/scripts/09-deploy-storage.sh"
    ;;

  indexing)
    run_phase 5 "Node Exporter"        "${SCRIPT_DIR}/scripts/06-node-exporter.sh"
    run_phase 6 "Indexing DePIN"       "${SCRIPT_DIR}/scripts/10-deploy-indexing.sh"
    ;;

  compute)
    run_phase 5 "Node Exporter"        "${SCRIPT_DIR}/scripts/06-node-exporter.sh"
    run_phase 6 "Compute DePIN"        "${SCRIPT_DIR}/scripts/11-deploy-compute.sh"
    ;;

  rtx)
    run_phase 5 "RTX Standby Prep"     "${SCRIPT_DIR}/scripts/12-rtx-standby.sh"
    ;;
esac

# ─── Final Validation ──────────────────────────────────────────────────────
echo ""
log_info "──────────────────────────────────────────────────────────"
log_info "  Post-Setup Validation"
log_info "──────────────────────────────────────────────────────────"
echo ""

bash "${SCRIPT_DIR}/scripts/healthcheck.sh"

echo ""
log_info "============================================================"
log_info "  Setup Complete: ${ROLE} (${TARGET_HOSTNAME})"
log_info "============================================================"
echo ""
log_info "Tailscale IP: $(get_tailscale_ip)"
log_info "Record this IP in scripts/00-common.sh and configs/prometheus/prometheus.yml"
echo ""

if [[ "$ROLE" != "monitoring" ]]; then
  log_info "Next steps:"
  log_info "  1. Add this node's Tailscale IP to the monitoring node's Prometheus config"
  log_info "  2. Verify this node appears in Grafana"
  if [[ "$ROLE" != "rtx" ]]; then
    log_info "  3. Edit docker-compose file with your chosen DePIN image, then:"
    case "$ROLE" in
      bandwidth) log_info "     cd docker-compose/bandwidth-depin && docker compose up -d" ;;
      storage)   log_info "     cd docker-compose/storage-depin && docker compose up -d" ;;
      indexing)  log_info "     cd docker-compose/indexing-depin && docker compose up -d" ;;
      compute)   log_info "     cd docker-compose/compute-depin && docker compose up -d" ;;
    esac
  fi
else
  log_info "Next steps:"
  log_info "  1. Change the default Grafana password (admin / changeme-depin-2025)"
  log_info "  2. Update configs/prometheus/prometheus.yml with Tailscale IPs from other nodes"
  log_info "  3. Restart Prometheus: cd docker-compose/monitoring && docker compose restart prometheus"
fi

log_ok "Done."
