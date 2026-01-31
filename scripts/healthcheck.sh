#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Quick Health Check (run from any node)
# Lightweight version of 99-validate.sh for daily use.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

echo ""
log_info "=== Quick Health Check — $(date) ==="
echo ""

# ─── Local Node Status ─────────────────────────────────────────────────────
log_info "── Local Node ──"
log_info "Hostname: $(get_hostname)"
log_info "Uptime: $(uptime -p 2>/dev/null || uptime)"
log_info "Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
log_info "Memory: $(free -h | awk '/^Mem:/ {printf "%s used / %s total (%s avail)", $3, $2, $7}')"
log_info "Swap: $(free -h | awk '/^Swap:/ {printf "%s used / %s total", $3, $2}')"
log_info "Disk /: $(df -h / | awk 'NR==2 {printf "%s used / %s total (%s)", $3, $2, $5}')"

if mountpoint -q /mnt/depin-storage 2>/dev/null; then
  log_info "Disk /mnt/depin-storage: $(df -h /mnt/depin-storage | awk 'NR==2 {printf "%s used / %s total (%s)", $3, $2, $5}')"
fi

# Temperature
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
  TEMP_C=$((TEMP / 1000))
  log_info "CPU Temp: ${TEMP_C}°C"
  if (( TEMP_C > 75 )); then
    log_warn "Temperature HIGH — thermal throttling likely!"
  fi
fi

echo ""

# ─── Docker Containers ─────────────────────────────────────────────────────
log_info "── Docker Containers ──"
if command -v docker &>/dev/null; then
  RUNNING=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
  if [[ -n "$RUNNING" ]]; then
    echo "$RUNNING"
  else
    log_info "No containers running."
  fi

  # Check for containers using excessive resources
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null || true
else
  log_info "Docker not installed."
fi

echo ""

# ─── Tailscale ──────────────────────────────────────────────────────────────
log_info "── Tailscale ──"
if command -v tailscale &>/dev/null; then
  log_info "IP: $(get_tailscale_ip)"
  tailscale status 2>/dev/null | head -10
else
  log_info "Tailscale not installed."
fi

echo ""

# ─── Network ───────────────────────────────────────────────────────────────
log_info "── Network Listeners ──"
LISTENERS=$(ss -tlnp 2>/dev/null | grep "0.0.0.0" | grep -v tailscale || true)
if [[ -n "$LISTENERS" ]]; then
  log_warn "Services bound to 0.0.0.0:"
  echo "$LISTENERS"
else
  log_ok "No services on 0.0.0.0"
fi

echo ""

# ─── GPU (if present) ──────────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
  log_info "── GPU Status ──"
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader 2>/dev/null || true
  echo ""
fi

log_ok "Health check complete."
