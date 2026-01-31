#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Common Variables & Functions
# =============================================================================
set -euo pipefail

# ─── Node Inventory ─────────────────────────────────────────────────────────
# Tailscale hostnames — matches Tailscale enrollment names.
declare -A NODES=(
  [pi4]="zpin-pi4"             # RPi 4  — Bandwidth DePIN
  [pi3-1]="zpin-pi3-1"         # RPi 3B+ — Storage DePIN (500 GB USB)
  [pi3-2]="zpin-pi3-2"         # RPi 3B+ — Indexing DePIN
  [pi3-mon]=""                 # RPi 3B+ — Monitoring & Control (TBD)
  [jetson]=""                  # Jetson Nano — On-Demand Compute DePIN (TBD)
  [rtx]="bitbots01"            # RTX PC (2× 3090) — Standby Only
  [laptop]="zAiNeY"            # Admin laptop — management only
)

# Tailscale IPs — fill in after `tailscale up` on each node
declare -A TS_IPS=(
  [pi4]=""
  [pi3-1]=""
  [pi3-2]=""
  [pi3-mon]=""
  [jetson]=""
  [rtx]=""
  [laptop]=""
)

# ─── Resource Limits ────────────────────────────────────────────────────────
# CPU limits expressed as Docker --cpus (fraction of total cores)
declare -A CPU_LIMITS=(
  [pi4]="0.60"     # 60% of RPi 4 quad-core = ~2.4 cores (bandwidth)
  [pi3-1]="0.50"   # 50% of RPi 3B+ quad-core = ~2.0 cores (storage)
  [pi3-2]="0.50"   # 50% of RPi 3B+ quad-core (indexing)
  [jetson]="0.50"   # Jetson Nano — CPU portion (compute)
)

# RAM limits
declare -A MEM_LIMITS=(
  [pi4]="1536m"    # 1.5 GB — bandwidth RPi 4 has 4 GB total
  [pi3-1]="512m"   # 512 MB — storage RPi 3B+ has 1 GB total
  [pi3-2]="512m"   # 512 MB — indexing RPi 3B+ has 1 GB total
  [jetson]="1024m"  # 1 GB — Jetson Nano 2 GB model
)

# Storage — 500 GB USB drive attached to zpin-pi3-1 (storage node)
STORAGE_DISK="/dev/sda"               # USB drive — VERIFY with `lsblk` before use
STORAGE_MOUNT="/mnt/depin-storage"
STORAGE_ALLOC_PERCENT=70

# ─── SSH ────────────────────────────────────────────────────────────────────
SSH_USER="zpin"
SSH_PORT=22

# ─── Docker ─────────────────────────────────────────────────────────────────
DOCKER_NETWORK="depin-net"
DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="3"

# ─── Monitoring ─────────────────────────────────────────────────────────────
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
NODE_EXPORTER_PORT=9100
ALERTMANAGER_PORT=9093
MQTT_PORT=1883

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Functions ──────────────────────────────────────────────────────────────

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

bail() {
  log_err "$@"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || bail "This script must be run as root."
}

require_cmd() {
  command -v "$1" &>/dev/null || bail "Required command not found: $1"
}

confirm() {
  local msg="${1:-Continue?}"
  read -rp "$(echo -e "${YELLOW}[?]${NC} ${msg} [y/N]: ")" ans
  [[ "${ans,,}" == "y" ]]
}

wait_for_apt() {
  local max_wait=120
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
    if (( waited >= max_wait )); then
      bail "Timed out waiting for apt lock."
    fi
    log_info "Waiting for apt lock..."
    sleep 5
    (( waited += 5 ))
  done
}

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64) echo "arm64" ;;
    armv7l)        echo "armhf" ;;
    x86_64)        echo "amd64" ;;
    *)             echo "$arch" ;;
  esac
}

check_internet() {
  if ! curl -sf --max-time 10 https://api.github.com >/dev/null 2>&1; then
    bail "No internet connectivity. Outbound HTTPS required."
  fi
  log_ok "Internet connectivity confirmed."
}

get_hostname() {
  hostname -s 2>/dev/null || cat /etc/hostname
}

get_tailscale_ip() {
  tailscale ip -4 2>/dev/null || echo "not-enrolled"
}

validate_no_inbound() {
  log_info "Validating no unexpected inbound listeners..."
  local listeners
  listeners=$(ss -tlnp | grep -v "127.0.0.1\|::1\|tailscale" | grep "0.0.0.0\|\*" || true)
  if [[ -n "$listeners" ]]; then
    log_warn "Found services bound to 0.0.0.0:"
    echo "$listeners"
    return 1
  fi
  log_ok "No services bound to 0.0.0.0 (outside Tailscale)."
  return 0
}
