#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 5: Deploy Monitoring Stack (depin-pi3-mon ONLY)
# This is the FIRST service deployed. All other nodes need this running first.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root
require_cmd docker

COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose/monitoring"

log_info "=== Deploying Monitoring Stack on $(get_hostname) ==="

# ─── Verify This is the Monitoring Node ─────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "depin-pi3-mon" ]]; then
  log_warn "Current hostname is '${CURRENT_HOST}', expected 'depin-pi3-mon'."
  confirm "Are you sure this is the monitoring node?" || bail "Aborting."
fi

# ─── Update Prometheus Config with Tailscale IPs ───────────────────────────
PROM_CONFIG="${SCRIPT_DIR}/../configs/prometheus/prometheus.yml"

log_info "Checking Prometheus config for placeholder IPs..."
if grep -q "TAILSCALE_IP_" "$PROM_CONFIG"; then
  log_warn "Prometheus config still has placeholder IPs."
  log_warn "Edit ${PROM_CONFIG} and replace all TAILSCALE_IP_* with actual IPs."
  log_info "You can find Tailscale IPs by running 'tailscale status' on each node."
  echo ""
  log_info "Placeholders to replace:"
  grep "TAILSCALE_IP_" "$PROM_CONFIG" | sed 's/^/  /'
  echo ""
  confirm "Continue with placeholder IPs? (monitoring will start but targets will fail)" || bail "Update IPs first."
fi

# ─── Update Nginx Binding to Tailscale IP ──────────────────────────────────
TS_IP=$(get_tailscale_ip)
if [[ "$TS_IP" != "not-enrolled" ]]; then
  log_info "Tailscale IP detected: ${TS_IP}"
  log_info "Updating docker-compose to bind to Tailscale IP..."
  # Update the ports to bind to Tailscale IP instead of 127.0.0.1
  sed -i "s|127.0.0.1:3000:3000|${TS_IP}:3000:3000|g" "${COMPOSE_DIR}/docker-compose.yml"
  sed -i "s|127.0.0.1:9090:9090|${TS_IP}:9090:9090|g" "${COMPOSE_DIR}/docker-compose.yml"
  sed -i "s|127.0.0.1:9093:9093|${TS_IP}:9093:9093|g" "${COMPOSE_DIR}/docker-compose.yml"
  log_ok "Ports bound to Tailscale IP: ${TS_IP}"
else
  log_warn "Tailscale not enrolled. Services will bind to 127.0.0.1 only."
fi

# ─── Create Data Directories ───────────────────────────────────────────────
mkdir -p /opt/depin/monitoring
log_ok "Data directories created."

# ─── Pull Images ────────────────────────────────────────────────────────────
log_info "Pulling Docker images (this may take a while on first run)..."
cd "$COMPOSE_DIR"
docker compose pull
log_ok "Images pulled."

# ─── Start Stack ────────────────────────────────────────────────────────────
log_info "Starting monitoring stack..."
docker compose up -d
log_ok "Monitoring stack started."

# ─── Wait for Services ─────────────────────────────────────────────────────
log_info "Waiting for services to become healthy..."
sleep 15

# Check each service
for svc in prometheus grafana alertmanager cadvisor node-exporter; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  if [[ "$STATUS" == "running" ]]; then
    log_ok "${svc}: running"
  else
    log_err "${svc}: ${STATUS}"
  fi
done

# ─── Verify Prometheus ──────────────────────────────────────────────────────
log_info "Verifying Prometheus..."
if curl -sf "http://localhost:9090/-/healthy" >/dev/null 2>&1; then
  log_ok "Prometheus is healthy."
else
  # Try via Tailscale IP
  if [[ "$TS_IP" != "not-enrolled" ]] && curl -sf "http://${TS_IP}:9090/-/healthy" >/dev/null 2>&1; then
    log_ok "Prometheus is healthy (via Tailscale)."
  else
    log_warn "Prometheus health check failed. It may still be starting up."
  fi
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "=== Monitoring Stack Deployed ==="
echo ""
if [[ "$TS_IP" != "not-enrolled" ]]; then
  log_info "Grafana:      http://${TS_IP}:3000  (admin / changeme-depin-2025)"
  log_info "Prometheus:   http://${TS_IP}:9090"
  log_info "Alertmanager: http://${TS_IP}:9093"
else
  log_info "Grafana:      http://localhost:3000  (admin / changeme-depin-2025)"
  log_info "Prometheus:   http://localhost:9090"
  log_info "Alertmanager: http://localhost:9093"
fi
echo ""
log_warn "CHANGE the default Grafana password immediately!"
log_warn "Update Prometheus config with Tailscale IPs for all nodes."
log_ok "Phase 5 complete. Next: run 06-node-exporter.sh on ALL other nodes."
