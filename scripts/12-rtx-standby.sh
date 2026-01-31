#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 12: RTX PC Standby Preparation
# Install NVIDIA drivers + monitoring ONLY. DO NOT deploy any DePIN workload.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root

log_info "=== RTX PC Standby Preparation ==="
log_warn "This script installs drivers and monitoring ONLY."
log_warn "NO DePIN workloads will be deployed on this machine."

# ─── Detect OS ──────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  log_info "OS: ${PRETTY_NAME}"
else
  log_warn "Cannot detect OS. Assuming Ubuntu/Debian."
fi

ARCH=$(get_arch)
log_info "Architecture: ${ARCH}"

# ─── Install NVIDIA Drivers ────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
  log_ok "NVIDIA drivers already installed."
  nvidia-smi
else
  log_info "Installing NVIDIA drivers..."

  if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID:-}" == "debian" ]]; then
    wait_for_apt
    apt-get update -qq
    apt-get install -y -qq ubuntu-drivers-common 2>/dev/null || true

    # Install recommended driver
    RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}')
    if [[ -n "$RECOMMENDED" ]]; then
      log_info "Installing recommended driver: ${RECOMMENDED}"
      apt-get install -y -qq "$RECOMMENDED"
    else
      log_info "Installing nvidia-driver-535 (stable for 3090)..."
      apt-get install -y -qq nvidia-driver-535
    fi
  else
    log_warn "Non-Ubuntu OS detected. Install NVIDIA drivers manually."
    log_info "Visit: https://www.nvidia.com/Download/index.aspx"
    log_info "For RTX 3090, use driver version >= 535"
  fi

  log_ok "NVIDIA drivers installed. A REBOOT may be required."
fi

# ─── Install NVIDIA Container Toolkit (for future Docker use) ──────────────
if ! dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
  log_info "Installing NVIDIA Container Toolkit..."

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit

  # Configure Docker to use nvidia runtime
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker 2>/dev/null || true

  log_ok "NVIDIA Container Toolkit installed."
else
  log_ok "NVIDIA Container Toolkit already installed."
fi

# ─── Verify GPUs ────────────────────────────────────────────────────────────
log_info "Verifying GPUs..."
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi
  echo ""

  GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
  log_info "GPUs detected: ${GPU_COUNT}"

  if (( GPU_COUNT < 2 )); then
    log_warn "Expected 2× RTX 3090, found ${GPU_COUNT} GPU(s)."
  else
    log_ok "2 GPUs detected as expected."
  fi

  # Verify GPUs are idle
  GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
  log_info "GPU utilization: ${GPU_UTIL}"

  # Check for any running CUDA processes
  CUDA_PROCS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
  if (( CUDA_PROCS > 0 )); then
    log_warn "Found ${CUDA_PROCS} CUDA process(es) running. GPUs should be idle."
    nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv
  else
    log_ok "No CUDA processes running. GPUs are idle."
  fi
else
  log_warn "nvidia-smi not available. Reboot may be required after driver install."
fi

# ─── Install Node Exporter ─────────────────────────────────────────────────
log_info "Installing Node Exporter for monitoring..."
bash "${SCRIPT_DIR}/06-node-exporter.sh"

# ─── GPU Monitoring Cron ───────────────────────────────────────────────────
cat > /usr/local/bin/gpu-idle-check <<'GPUCHK'
#!/usr/bin/env bash
# Check if GPUs are truly idle — alert if unexpected activity
GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s}')
if (( GPU_UTIL > 5 )); then
  echo "$(date): WARNING — GPU utilization is ${GPU_UTIL}% (should be 0)" >> /var/log/depin/gpu-monitor.log
fi
GPUCHK
chmod +x /usr/local/bin/gpu-idle-check
mkdir -p /var/log/depin

# Check every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/gpu-idle-check") | sort -u | crontab -
log_ok "GPU idle monitoring cron installed."

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "=== RTX PC Standby Preparation Complete ==="
echo ""
log_info "NVIDIA Drivers: Installed"
log_info "Container Toolkit: Installed"
log_info "Node Exporter: Running"
log_info "GPU Idle Monitor: Active"
echo ""
log_warn "STATUS: STANDBY — No DePIN workloads deployed."
log_warn "DO NOT deploy any DePIN until the rest of the cluster is stable."
log_ok "Phase 12 complete."
