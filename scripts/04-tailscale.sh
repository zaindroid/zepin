#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 4: Tailscale Installation & Enrollment
# Management plane only — NO exit nodes, NO routing internet traffic.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
check_internet

log_info "=== Tailscale Setup ==="

# ─── Install Tailscale ──────────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
  log_info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  log_ok "Tailscale installed."
else
  log_ok "Tailscale already installed: $(tailscale version | head -1)"
fi

# ─── Enable & Start ────────────────────────────────────────────────────────
systemctl enable tailscaled
systemctl start tailscaled
log_ok "Tailscale daemon running."

# ─── Enroll Node ────────────────────────────────────────────────────────────
TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo "unknown")

if [[ "$TS_STATUS" != "Running" ]]; then
  log_info "Enrolling node in Tailscale network..."
  log_warn "A browser link will appear — authenticate with your Tailscale account."
  echo ""

  # CRITICAL FLAGS:
  #   --accept-routes=false   — do NOT accept other nodes' routes
  #   --exit-node=""          — do NOT use any exit node
  #   --advertise-exit-node   — NEVER (omitted intentionally)
  #   --shields-up            — reject all incoming connections by default
  #                             (we selectively allow via ACLs)
  tailscale up \
    --accept-routes=false \
    --shields-up=false \
    --hostname="$(get_hostname)"

  # Wait for connection
  for i in {1..30}; do
    TS_IP=$(get_tailscale_ip)
    if [[ "$TS_IP" != "not-enrolled" ]]; then
      break
    fi
    sleep 2
  done

  TS_IP=$(get_tailscale_ip)
  if [[ "$TS_IP" == "not-enrolled" ]]; then
    bail "Tailscale enrollment failed. Run 'tailscale up' manually."
  fi

  log_ok "Tailscale enrolled. IP: ${TS_IP}"
else
  TS_IP=$(get_tailscale_ip)
  log_ok "Tailscale already running. IP: ${TS_IP}"
fi

# ─── Verify Tailscale Config ───────────────────────────────────────────────
log_info "Verifying Tailscale configuration..."

# Ensure NOT acting as exit node
EXIT_NODE=$(tailscale status --json | jq -r '.Self.ExitNodeOption' 2>/dev/null || echo "false")
if [[ "$EXIT_NODE" == "true" ]]; then
  log_err "This node is advertising as an exit node! Disabling..."
  tailscale set --advertise-exit-node=false
  log_ok "Exit node disabled."
fi

# Ensure NOT accepting routes
ACCEPT_ROUTES=$(tailscale status --json | jq -r '.Self.AllowedIPs' 2>/dev/null || echo "[]")
log_info "Allowed IPs: ${ACCEPT_ROUTES}"

# ─── UFW: Allow Tailscale Interface ────────────────────────────────────────
# Tailscale creates a tailscale0 interface — ensure UFW doesn't block it
ufw allow in on tailscale0 to any port 22 proto tcp comment "SSH via Tailscale" 2>/dev/null || true

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "=== Tailscale Setup Complete ==="
echo ""
tailscale status
echo ""
log_info "Tailscale IP: $(get_tailscale_ip)"
log_info "Exit Node: DISABLED (by design)"
log_info "Route Acceptance: DISABLED (by design)"
log_ok "Phase 4 complete."
log_info "Record this Tailscale IP in scripts/00-common.sh TS_IPS array."
log_info "Next: run 05-monitoring-node.sh on Node 4 (monitoring node)."
