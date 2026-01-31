#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 1: Base OS Setup (All Nodes)
# Run on each node individually after flashing OS.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root

NODE_NAME="${1:-}"
[[ -n "$NODE_NAME" ]] || bail "Usage: $0 <node-name>  (e.g., node1, node2, ...)"

log_info "=== Base OS Setup for ${NODE_NAME} ==="
log_info "Hostname: $(get_hostname)"
log_info "Architecture: $(get_arch)"

# ─── Set Hostname ───────────────────────────────────────────────────────────
DESIRED_HOSTNAME="${NODES[$NODE_NAME]:-}"
[[ -n "$DESIRED_HOSTNAME" ]] || bail "Unknown node: $NODE_NAME"

CURRENT_HOSTNAME=$(get_hostname)
if [[ "$CURRENT_HOSTNAME" != "$DESIRED_HOSTNAME" ]]; then
  log_info "Setting hostname to ${DESIRED_HOSTNAME}..."
  hostnamectl set-hostname "$DESIRED_HOSTNAME"
  echo "$DESIRED_HOSTNAME" > /etc/hostname
  # Update /etc/hosts
  sed -i "s/127.0.1.1.*/127.0.1.1\t${DESIRED_HOSTNAME}/" /etc/hosts
  log_ok "Hostname set to ${DESIRED_HOSTNAME}"
else
  log_ok "Hostname already correct: ${DESIRED_HOSTNAME}"
fi

# ─── System Update ──────────────────────────────────────────────────────────
log_info "Updating system packages..."
wait_for_apt
apt-get update -qq
apt-get upgrade -y -qq
log_ok "System updated."

# ─── Install Essential Packages ─────────────────────────────────────────────
log_info "Installing essential packages..."
apt-get install -y -qq \
  curl \
  wget \
  git \
  htop \
  iotop \
  net-tools \
  jq \
  ca-certificates \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common \
  unattended-upgrades \
  apt-listchanges \
  smartmontools \
  ufw \
  fail2ban \
  logrotate \
  chrony \
  rsync
log_ok "Essential packages installed."

# ─── Configure NTP (time sync is critical for DePIN) ────────────────────────
log_info "Configuring NTP via chrony..."
systemctl enable chrony
systemctl start chrony
chronyc makestep >/dev/null 2>&1 || true
log_ok "Time synchronization configured."

# ─── Enable Automatic Security Updates ──────────────────────────────────────
log_info "Configuring automatic security updates..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades
log_ok "Automatic security updates enabled."

# ─── Create DePIN User ──────────────────────────────────────────────────────
if ! id "$SSH_USER" &>/dev/null; then
  log_info "Creating user '${SSH_USER}'..."
  useradd -m -s /bin/bash -G sudo,docker "$SSH_USER" 2>/dev/null || \
  useradd -m -s /bin/bash -G sudo "$SSH_USER"
  # Lock password — key-only auth
  passwd -l "$SSH_USER"
  log_ok "User '${SSH_USER}' created (password locked)."
else
  log_ok "User '${SSH_USER}' already exists."
fi

# ─── SSH Key Directory ──────────────────────────────────────────────────────
SSH_DIR="/home/${SSH_USER}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${SSH_USER}:${SSH_USER}" "$SSH_DIR"
log_info "SSH key directory prepared at ${SSH_DIR}/authorized_keys"
log_warn ">>> ADD YOUR PUBLIC KEY to ${SSH_DIR}/authorized_keys <<<"

# ─── Kernel Tuning (minimal, safe for ARM) ──────────────────────────────────
log_info "Applying kernel tuning..."
cat > /etc/sysctl.d/99-depin.conf <<'EOF'
# Reduce swap usage — prefer RAM
vm.swappiness=10

# Increase inotify watchers for monitoring
fs.inotify.max_user_watches=524288

# Network tuning — outbound performance
net.core.somaxconn=1024
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30

# Disable IPv6 if not needed (reduce attack surface)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

sysctl --system >/dev/null 2>&1
log_ok "Kernel parameters applied."

# ─── Configure Logrotate for DePIN Logs ─────────────────────────────────────
cat > /etc/logrotate.d/depin <<'EOF'
/var/log/depin/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF
mkdir -p /var/log/depin
log_ok "Log rotation configured."

# ─── Swap (ensure at least 1 GB on RPi) ─────────────────────────────────────
SWAP_SIZE=$(free -m | awk '/^Swap:/ {print $2}')
if (( SWAP_SIZE < 1024 )); then
  log_info "Configuring 1 GB swap..."
  if [[ -f /etc/dphys-swapfile ]]; then
    sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
    systemctl restart dphys-swapfile 2>/dev/null || true
  else
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
  fi
  log_ok "Swap configured."
else
  log_ok "Swap already sufficient: ${SWAP_SIZE} MB"
fi

# ─── Final Verification ────────────────────────────────────────────────────
log_info "=== Base Setup Complete ==="
log_info "Hostname: $(get_hostname)"
log_info "Architecture: $(get_arch)"
log_info "Kernel: $(uname -r)"
log_info "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
log_info "Swap: $(free -h | awk '/^Swap:/ {print $2}')"
log_ok "Phase 1 complete for ${NODE_NAME}. Next: run 02-security.sh"
