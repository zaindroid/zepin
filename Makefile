# =============================================================================
# DePIN Edge Cluster — Orchestration Makefile
# Usage: make <target>
#
# DEPLOYMENT ORDER (strict):
#   1. make base-all       — OS setup on each node
#   2. make secure-all     — Security hardening
#   3. make docker-all     — Docker installation
#   4. make tailscale-all  — Tailscale enrollment
#   5. make monitoring     — Deploy monitoring stack (zpin-pi3-mon)
#   6. make exporters-all  — Node exporters on all nodes
#   7. make storage-prep   — Prepare 500 GB disk (zpin-pi3-1)
#   8. make deploy-bandwidth — Bandwidth DePIN (zpin-pi4)
#   *** WAIT 72 HOURS — VERIFY STABILITY ***
#   9. make deploy-storage — Storage DePIN (zpin-pi3-1)
#  10. make deploy-indexing — Indexing DePIN (zpin-pi3-2)
#  11. make deploy-compute — Compute DePIN (zpin-jetson)
#  12. make rtx-prep       — RTX standby preparation
#  13. make validate       — Full cluster validation
# =============================================================================

SHELL := /bin/bash
SCRIPTS := scripts
SSH_USER := zpin

# ─── Tailscale IPs (fill in after enrollment) ──────────────────────────────
PI4_IP      := 100.95.75.61
PI3_1_IP    :=
PI3_2_IP    := 100.118.198.114
PI3_MON_IP  :=
JETSON_IP   :=
RTX_IP      :=

# ─── Remote Execution Helper ───────────────────────────────────────────────
define ssh_run
	@echo ">>> Running on $(1) ($(2))..."
	ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $(SSH_USER)@$(2) "sudo bash -s" < $(3)
endef

# =============================================================================
# PHASE 1: Base Setup
# =============================================================================
.PHONY: base-pi4 base-pi3-1 base-pi3-2 base-pi3-mon base-jetson base-all

base-pi4:
	$(call ssh_run,zpin-pi4,$(PI4_IP),$(SCRIPTS)/01-base-setup.sh pi4)

base-pi3-1:
	$(call ssh_run,zpin-pi3-1,$(PI3_1_IP),$(SCRIPTS)/01-base-setup.sh pi3-1)

base-pi3-2:
	$(call ssh_run,zpin-pi3-2,$(PI3_2_IP),$(SCRIPTS)/01-base-setup.sh pi3-2)

base-pi3-mon:
	$(call ssh_run,zpin-pi3-mon,$(PI3_MON_IP),$(SCRIPTS)/01-base-setup.sh pi3-mon)

base-jetson:
	$(call ssh_run,zpin-jetson,$(JETSON_IP),$(SCRIPTS)/01-base-setup.sh jetson)

base-all: base-pi4 base-pi3-1 base-pi3-2 base-pi3-mon base-jetson
	@echo "=== Base setup complete on all nodes ==="

# =============================================================================
# PHASE 2: Security Hardening
# =============================================================================
.PHONY: secure-pi4 secure-pi3-1 secure-pi3-2 secure-pi3-mon secure-jetson secure-all

secure-pi4:
	$(call ssh_run,zpin-pi4,$(PI4_IP),$(SCRIPTS)/02-security.sh)

secure-pi3-1:
	$(call ssh_run,zpin-pi3-1,$(PI3_1_IP),$(SCRIPTS)/02-security.sh)

secure-pi3-2:
	$(call ssh_run,zpin-pi3-2,$(PI3_2_IP),$(SCRIPTS)/02-security.sh)

secure-pi3-mon:
	$(call ssh_run,zpin-pi3-mon,$(PI3_MON_IP),$(SCRIPTS)/02-security.sh)

secure-jetson:
	$(call ssh_run,zpin-jetson,$(JETSON_IP),$(SCRIPTS)/02-security.sh)

secure-all: secure-pi4 secure-pi3-1 secure-pi3-2 secure-pi3-mon secure-jetson
	@echo "=== Security hardening complete on all nodes ==="

# =============================================================================
# PHASE 3: Docker
# =============================================================================
.PHONY: docker-pi4 docker-pi3-1 docker-pi3-2 docker-pi3-mon docker-jetson docker-all

docker-pi4:
	$(call ssh_run,zpin-pi4,$(PI4_IP),$(SCRIPTS)/03-docker-install.sh)

docker-pi3-1:
	$(call ssh_run,zpin-pi3-1,$(PI3_1_IP),$(SCRIPTS)/03-docker-install.sh)

docker-pi3-2:
	$(call ssh_run,zpin-pi3-2,$(PI3_2_IP),$(SCRIPTS)/03-docker-install.sh)

docker-pi3-mon:
	$(call ssh_run,zpin-pi3-mon,$(PI3_MON_IP),$(SCRIPTS)/03-docker-install.sh)

docker-jetson:
	$(call ssh_run,zpin-jetson,$(JETSON_IP),$(SCRIPTS)/03-docker-install.sh)

docker-all: docker-pi4 docker-pi3-1 docker-pi3-2 docker-pi3-mon docker-jetson
	@echo "=== Docker installed on all nodes ==="

# =============================================================================
# PHASE 4: Tailscale (interactive — run on each node individually)
# =============================================================================
.PHONY: tailscale-all

tailscale-all:
	@echo "Tailscale requires interactive auth on each node."
	@echo "SSH into each node and run: sudo bash scripts/04-tailscale.sh"
	@echo ""
	@echo "Nodes to enroll:"
	@echo "  ssh $(SSH_USER)@<LAN-IP>  # for each node"
	@echo ""
	@echo "After enrollment, update Tailscale IPs in:"
	@echo "  - scripts/00-common.sh (TS_IPS array)"
	@echo "  - configs/prometheus/prometheus.yml"
	@echo "  - This Makefile (top section)"

# =============================================================================
# PHASE 5: Monitoring (zpin-pi3-mon only — deploy FIRST)
# =============================================================================
.PHONY: monitoring

monitoring:
	@echo ">>> Deploying monitoring stack on zpin-pi3-mon..."
	@echo "SCP configs to monitoring node first:"
	rsync -avz --exclude='.git' ./ $(SSH_USER)@$(PI3_MON_IP):~/depin-cluster/
	ssh -o ConnectTimeout=10 $(SSH_USER)@$(PI3_MON_IP) "cd ~/depin-cluster && sudo bash scripts/05-monitoring-node.sh"

# =============================================================================
# PHASE 6: Node Exporters
# =============================================================================
.PHONY: exporters-all

exporters-all:
	$(call ssh_run,zpin-pi4,$(PI4_IP),$(SCRIPTS)/06-node-exporter.sh)
	$(call ssh_run,zpin-pi3-1,$(PI3_1_IP),$(SCRIPTS)/06-node-exporter.sh)
	$(call ssh_run,zpin-pi3-2,$(PI3_2_IP),$(SCRIPTS)/06-node-exporter.sh)
	$(call ssh_run,zpin-jetson,$(JETSON_IP),$(SCRIPTS)/06-node-exporter.sh)
	@echo "=== Node exporters installed on all nodes ==="

# =============================================================================
# PHASE 7+: DePIN Deployments
# =============================================================================
.PHONY: storage-prep deploy-bandwidth deploy-storage deploy-indexing deploy-compute rtx-prep

storage-prep:
	$(call ssh_run,zpin-pi3-1,$(PI3_1_IP),$(SCRIPTS)/07-storage-prep.sh)

deploy-bandwidth:
	@echo ">>> Deploying bandwidth DePIN on zpin-pi4..."
	rsync -avz docker-compose/bandwidth-depin/ $(SSH_USER)@$(PI4_IP):~/depin-cluster/docker-compose/bandwidth-depin/
	ssh $(SSH_USER)@$(PI4_IP) "cd ~/depin-cluster && sudo bash scripts/08-deploy-bandwidth.sh"

deploy-storage:
	@echo ">>> Deploying storage DePIN on zpin-pi3-1..."
	rsync -avz docker-compose/storage-depin/ $(SSH_USER)@$(PI3_1_IP):~/depin-cluster/docker-compose/storage-depin/
	ssh $(SSH_USER)@$(PI3_1_IP) "cd ~/depin-cluster && sudo bash scripts/09-deploy-storage.sh"

deploy-indexing:
	@echo ">>> Deploying indexing DePIN on zpin-pi3-2..."
	rsync -avz docker-compose/indexing-depin/ $(SSH_USER)@$(PI3_2_IP):~/depin-cluster/docker-compose/indexing-depin/
	ssh $(SSH_USER)@$(PI3_2_IP) "cd ~/depin-cluster && sudo bash scripts/10-deploy-indexing.sh"

deploy-compute:
	@echo ">>> Deploying compute DePIN on zpin-jetson..."
	rsync -avz docker-compose/compute-depin/ $(SSH_USER)@$(JETSON_IP):~/depin-cluster/docker-compose/compute-depin/
	ssh $(SSH_USER)@$(JETSON_IP) "cd ~/depin-cluster && sudo bash scripts/11-deploy-compute.sh"

rtx-prep:
	$(call ssh_run,bitbots01,$(RTX_IP),$(SCRIPTS)/12-rtx-standby.sh)

# =============================================================================
# VALIDATION & HEALTH
# =============================================================================
.PHONY: validate health status

validate:
	@bash $(SCRIPTS)/99-validate.sh

health:
	@bash $(SCRIPTS)/healthcheck.sh

status:
	@echo "=== Cluster Status ==="
	@echo ""
	@tailscale status 2>/dev/null || echo "Tailscale not available on this machine"
	@echo ""
	@echo "=== Monitoring ==="
	@curl -sf "http://$(PI3_MON_IP):9090/api/v1/targets" 2>/dev/null \
		| jq -r '.data.activeTargets[] | "\(.labels.node)\t\(.health)\t\(.lastScrape)"' 2>/dev/null \
		| column -t \
		|| echo "Cannot reach Prometheus at $(PI3_MON_IP):9090"

# =============================================================================
# UTILITIES
# =============================================================================
.PHONY: sync-all logs-all help

sync-all:
	@echo "Syncing cluster configs to all nodes..."
	@for ip in $(PI4_IP) $(PI3_1_IP) $(PI3_2_IP) $(PI3_MON_IP) $(JETSON_IP); do \
		echo "  Syncing to $$ip..."; \
		rsync -avz --exclude='.git' ./ $(SSH_USER)@$$ip:~/depin-cluster/ 2>/dev/null || echo "  FAILED: $$ip"; \
	done

logs-all:
	@echo "=== Container Logs (last 10 lines per node) ==="
	@for ip in $(PI4_IP) $(PI3_1_IP) $(PI3_2_IP) $(PI3_MON_IP) $(JETSON_IP); do \
		echo ""; \
		echo "--- $$ip ---"; \
		ssh -o ConnectTimeout=5 $(SSH_USER)@$$ip "docker ps -q | xargs -r docker logs --tail=10 2>/dev/null" 2>/dev/null || echo "  Cannot connect"; \
	done

help:
	@echo "DePIN Edge Cluster — Available Targets"
	@echo ""
	@echo "  SETUP (run in order):"
	@echo "    base-all        OS setup on all nodes"
	@echo "    secure-all      Security hardening"
	@echo "    docker-all      Docker installation"
	@echo "    tailscale-all   Tailscale enrollment (interactive)"
	@echo "    monitoring      Deploy monitoring stack"
	@echo "    exporters-all   Node exporters on all nodes"
	@echo ""
	@echo "  DEPLOY (run in order, wait 72h after first):"
	@echo "    storage-prep    Prepare 500 GB disk"
	@echo "    deploy-bandwidth  Bandwidth DePIN (zpin-pi4)"
	@echo "    deploy-storage    Storage DePIN (zpin-pi3-1)"
	@echo "    deploy-indexing   Indexing DePIN (zpin-pi3-2)"
	@echo "    deploy-compute    Compute DePIN (zpin-jetson)"
	@echo "    rtx-prep          RTX standby prep"
	@echo ""
	@echo "  OPS:"
	@echo "    validate    Full cluster validation"
	@echo "    health      Quick health check"
	@echo "    status      Cluster status overview"
	@echo "    sync-all    Sync configs to all nodes"
	@echo "    logs-all    Tail container logs"
