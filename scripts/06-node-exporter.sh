#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 6: Node Exporter (All Nodes Except Monitoring)
# Runs as a systemd service (not Docker) for reliability.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
check_internet

log_info "=== Installing Node Exporter on $(get_hostname) ==="

ARCH=$(get_arch)
NODE_EXPORTER_VERSION="1.7.0"

# ─── Skip if Already Running ───────────────────────────────────────────────
if systemctl is-active node_exporter &>/dev/null; then
  log_ok "Node Exporter already running."
  systemctl status node_exporter --no-pager -l | head -10
  exit 0
fi

# ─── Download ───────────────────────────────────────────────────────────────
case "$ARCH" in
  arm64)  ARCH_DL="arm64" ;;
  armhf)  ARCH_DL="armv7" ;;
  amd64)  ARCH_DL="amd64" ;;
  *)      bail "Unsupported architecture: $ARCH" ;;
esac

TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_DL}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

log_info "Downloading Node Exporter v${NODE_EXPORTER_VERSION} for ${ARCH_DL}..."
cd /tmp
curl -fsSLO "$DOWNLOAD_URL"
tar xzf "$TARBALL"
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_DL}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
rm -rf "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_DL}" "/tmp/${TARBALL}"
log_ok "Node Exporter binary installed."

# ─── Create Systemd User ───────────────────────────────────────────────────
if ! id node_exporter &>/dev/null; then
  useradd --no-create-home --shell /bin/false node_exporter
fi

# ─── Systemd Service ───────────────────────────────────────────────────────
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|run)($$|/)" \
  --collector.systemd \
  --collector.processes
Restart=always
RestartSec=5
SyslogIdentifier=node_exporter

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ReadOnlyPaths=/

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# ─── Verify ─────────────────────────────────────────────────────────────────
sleep 2
if systemctl is-active node_exporter &>/dev/null; then
  log_ok "Node Exporter is running."
  curl -sf "http://localhost:9100/metrics" | head -5
else
  log_err "Node Exporter failed to start."
  journalctl -u node_exporter --no-pager -n 20
  bail "Check logs above."
fi

log_info "=== Node Exporter Installed ==="
log_info "Metrics available at http://$(get_tailscale_ip):9100/metrics"
log_ok "Phase 6 complete."
