#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 2: Security Hardening (All Nodes)
# Firewall (UFW) + SSH hardening + Fail2Ban
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root

log_info "=== Security Hardening ==="

# ─── UFW Firewall ───────────────────────────────────────────────────────────
log_info "Configuring UFW firewall..."

# Reset to clean state
ufw --force reset >/dev/null 2>&1

# Default policies: deny inbound, allow outbound
ufw default deny incoming
ufw default allow outgoing

# Allow SSH from LAN subnets (adjust to your dorm network)
# Common private ranges — narrow these to your actual subnet
ufw allow from 10.0.0.0/8 to any port 22 proto tcp comment "SSH from LAN"
ufw allow from 172.16.0.0/12 to any port 22 proto tcp comment "SSH from LAN"
ufw allow from 192.168.0.0/16 to any port 22 proto tcp comment "SSH from LAN"

# Allow SSH from Tailscale subnet
ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "SSH from Tailscale"

# Allow monitoring ports ONLY from Tailscale
ufw allow from 100.64.0.0/10 to any port 9090 proto tcp comment "Prometheus from Tailscale"
ufw allow from 100.64.0.0/10 to any port 9100 proto tcp comment "Node Exporter from Tailscale"
ufw allow from 100.64.0.0/10 to any port 3000 proto tcp comment "Grafana from Tailscale"
ufw allow from 100.64.0.0/10 to any port 9093 proto tcp comment "Alertmanager from Tailscale"

# Allow MQTT from LAN/Tailscale only (for ESP32)
ufw allow from 192.168.0.0/16 to any port 1883 proto tcp comment "MQTT from LAN"
ufw allow from 100.64.0.0/10 to any port 1883 proto tcp comment "MQTT from Tailscale"

# Enable firewall
ufw --force enable
log_ok "UFW firewall enabled."

# Show status
ufw status verbose

# ─── SSH Hardening ──────────────────────────────────────────────────────────
log_info "Hardening SSH configuration..."

# Backup original
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

cat > /etc/ssh/sshd_config.d/99-depin-hardening.conf <<'EOF'
# DePIN Cluster SSH Hardening
# ----------------------------

# Disable password authentication — keys only
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Disable root login
PermitRootLogin no

# Key-based auth only
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Limit login attempts
MaxAuthTries 3
MaxSessions 5

# Timeouts
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused auth methods
KerberosAuthentication no
GSSAPIAuthentication no

# Disable X11 forwarding
X11Forwarding no

# Disable agent forwarding (not needed)
AllowAgentForwarding no

# Restrict to specific users (uncomment and adjust)
# AllowUsers depin

# Logging
LogLevel VERBOSE

# Disable TCP forwarding (we use Tailscale)
AllowTcpForwarding no

# Banner
Banner none
EOF

# Validate sshd config before restarting
sshd -t 2>/dev/null
if [[ $? -eq 0 ]]; then
  systemctl restart sshd
  log_ok "SSH hardened and restarted."
else
  log_err "SSH config validation failed! Restoring backup."
  rm -f /etc/ssh/sshd_config.d/99-depin-hardening.conf
  bail "Fix SSH config manually."
fi

# ─── Fail2Ban ───────────────────────────────────────────────────────────────
log_info "Configuring Fail2Ban..."

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 3
bantime = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log_ok "Fail2Ban configured and running."

# ─── Disable Unnecessary Services ───────────────────────────────────────────
log_info "Disabling unnecessary services..."
DISABLE_SERVICES=(
  avahi-daemon
  bluetooth
  cups
  cups-browsed
  ModemManager
)

for svc in "${DISABLE_SERVICES[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    log_info "Disabled: $svc"
  fi
done
log_ok "Unnecessary services disabled."

# ─── File Permissions ──────────────────────────────────────────────────────
log_info "Tightening file permissions..."
chmod 700 /root
chmod 600 /etc/ssh/sshd_config
chmod 644 /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
log_ok "File permissions tightened."

# ─── Verify No Services on 0.0.0.0 ─────────────────────────────────────────
log_info "Checking for services bound to 0.0.0.0..."
validate_no_inbound || log_warn "Review the above listeners and restrict them."

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "=== Security Hardening Complete ==="
echo ""
log_info "Firewall: ACTIVE (deny inbound, allow outbound)"
log_info "SSH: Key-only, no root, no password"
log_info "Fail2Ban: Enabled (3 attempts, 1h ban)"
log_info "Auto-updates: Enabled"
echo ""
log_warn "IMPORTANT: Ensure your SSH public key is in /home/${SSH_USER}/.ssh/authorized_keys"
log_warn "IMPORTANT: Test SSH access BEFORE closing your current session!"
log_ok "Phase 2 complete. Next: run 03-docker-install.sh"
