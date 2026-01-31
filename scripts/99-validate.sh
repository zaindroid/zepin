#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Full Cluster Validation
# Run from any node with Tailscale access (ideally your laptop).
# Checks ALL success criteria from the deployment spec.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

log_info "============================================================"
log_info "  DePIN Edge Cluster — Full Validation"
log_info "  Date: $(date)"
log_info "============================================================"
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() { ((PASS++)); log_ok "PASS: $*"; }
check_fail() { ((FAIL++)); log_err "FAIL: $*"; }
check_warn() { ((WARN++)); log_warn "WARN: $*"; }

# =============================================================================
# 1. TAILSCALE CONNECTIVITY
# =============================================================================
log_info "── 1. Tailscale Connectivity ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]]; then
    check_warn "${node_name}: Tailscale IP not configured in 00-common.sh"
    continue
  fi

  if ping -c 1 -W 3 "$ts_ip" &>/dev/null; then
    check_pass "${node_name} (${ts_ip}) reachable via Tailscale"
  else
    check_fail "${node_name} (${ts_ip}) NOT reachable via Tailscale"
  fi
done
echo ""

# =============================================================================
# 2. NO INBOUND WAN PORTS (per-node check via SSH)
# =============================================================================
log_info "── 2. Inbound Port Check ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]]; then continue; fi
  if [[ "$node_key" == "laptop" ]]; then continue; fi

  # Check for services bound to 0.0.0.0 (excluding Tailscale and loopback)
  LISTENERS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "ss -tlnp 2>/dev/null | grep '0.0.0.0' | grep -v tailscale || true" 2>/dev/null)

  if [[ -z "$LISTENERS" ]]; then
    check_pass "${node_name}: No services bound to 0.0.0.0"
  else
    check_warn "${node_name}: Services found on 0.0.0.0:"
    echo "    $LISTENERS"
  fi
done
echo ""

# =============================================================================
# 3. FIREWALL STATUS
# =============================================================================
log_info "── 3. Firewall Status ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]] || [[ "$node_key" == "laptop" ]]; then continue; fi

  UFW_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "sudo ufw status 2>/dev/null | head -1" 2>/dev/null)

  if echo "$UFW_STATUS" | grep -qi "active"; then
    check_pass "${node_name}: UFW firewall ACTIVE"
  else
    check_fail "${node_name}: UFW firewall NOT active"
  fi
done
echo ""

# =============================================================================
# 4. SSH KEY-ONLY AUTH
# =============================================================================
log_info "── 4. SSH Configuration ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]] || [[ "$node_key" == "laptop" ]]; then continue; fi

  PASS_AUTH=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "grep -i '^PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1" 2>/dev/null)

  if echo "$PASS_AUTH" | grep -qi "no"; then
    check_pass "${node_name}: Password auth DISABLED"
  else
    check_warn "${node_name}: Password auth may be enabled: ${PASS_AUTH}"
  fi
done
echo ""

# =============================================================================
# 5. DOCKER CONTAINERS
# =============================================================================
log_info "── 5. Docker Container Status ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]] || [[ "$node_key" == "laptop" ]]; then continue; fi

  CONTAINERS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null" 2>/dev/null)

  if [[ -z "$CONTAINERS" ]]; then
    if [[ "$node_key" == "pi3-mon" ]]; then
      check_fail "${node_name}: No Docker containers running (monitoring expected)"
    else
      log_info "${node_name}: No Docker containers (may be pre-deployment)"
    fi
  else
    CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -l)
    log_info "${node_name}: ${CONTAINER_COUNT} container(s):"
    echo "$CONTAINERS" | while read -r line; do
      echo "    $line"
    done

    # Check no node has more than 1 DePIN container (monitoring node excluded)
    if [[ "$node_key" != "pi3-mon" ]]; then
      DEPIN_COUNT=$(echo "$CONTAINERS" | grep -ci "depin" || true)
      if (( DEPIN_COUNT > 1 )); then
        check_fail "${node_name}: Multiple DePIN containers (${DEPIN_COUNT}). Rule: ONE per node."
      elif (( DEPIN_COUNT == 1 )); then
        check_pass "${node_name}: Exactly 1 DePIN container"
      fi
    fi
  fi
done
echo ""

# =============================================================================
# 6. RESOURCE LIMITS
# =============================================================================
log_info "── 6. Container Resource Limits ──"

for node_key in "${!NODES[@]}"; do
  node_name="${NODES[$node_key]}"
  ts_ip="${TS_IPS[$node_key]}"

  if [[ -z "$ts_ip" ]] || [[ "$node_key" == "laptop" ]]; then continue; fi

  LIMITS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "docker inspect --format '{{.Name}}: CPU={{.HostConfig.NanoCpus}} MEM={{.HostConfig.Memory}}' \$(docker ps -q) 2>/dev/null" 2>/dev/null)

  if [[ -n "$LIMITS" ]]; then
    echo "$LIMITS" | while read -r line; do
      if echo "$line" | grep -q "CPU=0 MEM=0"; then
        check_warn "${node_name}: Container has NO resource limits: $line"
      else
        check_pass "${node_name}: Resource limits set: $line"
      fi
    done
  fi
done
echo ""

# =============================================================================
# 7. MONITORING STACK
# =============================================================================
log_info "── 7. Monitoring Stack ──"

MON_IP="${TS_IPS[pi3-mon]}"
if [[ -n "$MON_IP" ]]; then
  # Prometheus
  if curl -sf --max-time 5 "http://${MON_IP}:9090/-/healthy" &>/dev/null; then
    check_pass "Prometheus healthy at ${MON_IP}:9090"
  else
    check_fail "Prometheus NOT reachable at ${MON_IP}:9090"
  fi

  # Grafana
  if curl -sf --max-time 5 "http://${MON_IP}:3000/api/health" &>/dev/null; then
    check_pass "Grafana healthy at ${MON_IP}:3000"
  else
    check_fail "Grafana NOT reachable at ${MON_IP}:3000"
  fi

  # Alertmanager
  if curl -sf --max-time 5 "http://${MON_IP}:9093/-/healthy" &>/dev/null; then
    check_pass "Alertmanager healthy at ${MON_IP}:9093"
  else
    check_fail "Alertmanager NOT reachable at ${MON_IP}:9093"
  fi

  # Check Prometheus targets
  TARGETS=$(curl -sf --max-time 5 "http://${MON_IP}:9090/api/v1/targets" 2>/dev/null)
  if [[ -n "$TARGETS" ]]; then
    UP_COUNT=$(echo "$TARGETS" | jq '[.data.activeTargets[] | select(.health=="up")] | length' 2>/dev/null || echo "?")
    DOWN_COUNT=$(echo "$TARGETS" | jq '[.data.activeTargets[] | select(.health!="up")] | length' 2>/dev/null || echo "?")
    log_info "Prometheus targets: ${UP_COUNT} UP, ${DOWN_COUNT} DOWN"
    if [[ "$DOWN_COUNT" != "0" ]] && [[ "$DOWN_COUNT" != "?" ]]; then
      check_warn "Some Prometheus targets are down"
    fi
  fi
else
  check_warn "Monitoring node IP not configured — skipping checks"
fi
echo ""

# =============================================================================
# 8. STORAGE HEALTH (depin-pi3-1)
# =============================================================================
log_info "── 8. Storage Health ──"

STORAGE_IP="${TS_IPS[pi3-1]}"
if [[ -n "$STORAGE_IP" ]]; then
  DISK_INFO=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${STORAGE_IP}" \
    "df -h /mnt/depin-storage 2>/dev/null | tail -1" 2>/dev/null)

  if [[ -n "$DISK_INFO" ]]; then
    DISK_USAGE=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')
    check_pass "Storage mounted. Usage: ${DISK_USAGE}%"
    if (( DISK_USAGE > 85 )); then
      check_warn "Storage usage above 85%!"
    fi
  else
    check_fail "Storage not mounted at /mnt/depin-storage on depin-pi3-1"
  fi

  # SMART check
  SMART=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${STORAGE_IP}" \
    "sudo smartctl -H /dev/sda 2>/dev/null | grep -i 'overall\|result' || echo 'N/A'" 2>/dev/null)
  log_info "SMART status: ${SMART}"
else
  check_warn "Storage node IP not configured"
fi
echo ""

# =============================================================================
# 9. RTX STANDBY VERIFICATION
# =============================================================================
log_info "── 9. RTX PC Standby ──"

RTX_IP="${TS_IPS[rtx]}"
if [[ -n "$RTX_IP" ]]; then
  GPU_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${RTX_IP}" \
    "nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null" 2>/dev/null)

  if [[ -n "$GPU_STATUS" ]]; then
    log_info "GPU status: ${GPU_STATUS}"

    CUDA_PROCS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "${SSH_USER}@${RTX_IP}" \
      "nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l" 2>/dev/null)

    if (( CUDA_PROCS == 0 )); then
      check_pass "RTX GPUs idle — no CUDA processes"
    else
      check_fail "RTX GPUs NOT idle — ${CUDA_PROCS} CUDA process(es) found"
    fi
  else
    check_warn "Cannot read GPU status from RTX PC"
  fi
else
  check_warn "RTX PC IP not configured"
fi
echo ""

# =============================================================================
# 10. NO-GO RULE VERIFICATION
# =============================================================================
log_info "── 10. No-Go Rules ──"

# Check no Tailscale exit nodes
for node_key in "${!NODES[@]}"; do
  ts_ip="${TS_IPS[$node_key]}"
  if [[ -z "$ts_ip" ]] || [[ "$node_key" == "laptop" ]]; then continue; fi

  EXIT_NODE=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${ts_ip}" \
    "tailscale status --json 2>/dev/null | jq -r '.Self.ExitNodeOption // false'" 2>/dev/null)

  if [[ "$EXIT_NODE" == "true" ]]; then
    check_fail "${NODES[$node_key]}: Acting as Tailscale EXIT NODE!"
  else
    check_pass "${NODES[$node_key]}: Not an exit node"
  fi
done
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
log_info "============================================================"
log_info "  VALIDATION SUMMARY"
log_info "============================================================"
echo ""
log_ok   "PASSED:   ${PASS}"
log_warn "WARNINGS: ${WARN}"
log_err  "FAILED:   ${FAIL}"
echo ""

if (( FAIL > 0 )); then
  log_err "Cluster has ${FAIL} FAILURE(s). Address before proceeding."
  exit 1
elif (( WARN > 0 )); then
  log_warn "Cluster has ${WARN} warning(s). Review and resolve."
  exit 0
else
  log_ok "All checks PASSED. Cluster is operational."
  exit 0
fi
