#!/usr/bin/env bash
# =============================================================================
# DePIN Edge Cluster — Phase 7: Storage Disk Preparation (depin-pi3-1 ONLY)
# Prepares the 500 GB USB drive for the storage DePIN.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-common.sh"

require_root

log_info "=== Storage Disk Preparation on $(get_hostname) ==="

# ─── Verify This is the Storage Node ───────────────────────────────────────
CURRENT_HOST=$(get_hostname)
if [[ "$CURRENT_HOST" != "depin-pi3-1" ]]; then
  log_warn "Current hostname is '${CURRENT_HOST}', expected 'depin-pi3-1'."
  confirm "Are you sure this is the storage node with 500 GB USB?" || bail "Aborting."
fi

# ─── Detect USB Drive ──────────────────────────────────────────────────────
log_info "Current block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
echo ""

if [[ ! -b "$STORAGE_DISK" ]]; then
  log_err "Storage disk ${STORAGE_DISK} not found!"
  log_info "Available disks:"
  lsblk -d -o NAME,SIZE,MODEL | grep -v "^NAME"
  bail "Update STORAGE_DISK in 00-common.sh to match your USB drive."
fi

DISK_SIZE=$(lsblk -bdn -o SIZE "$STORAGE_DISK" 2>/dev/null)
DISK_SIZE_GB=$((DISK_SIZE / 1073741824))
DISK_MODEL=$(lsblk -dn -o MODEL "$STORAGE_DISK" 2>/dev/null | xargs)

log_info "Detected disk: ${STORAGE_DISK}"
log_info "Size: ${DISK_SIZE_GB} GB"
log_info "Model: ${DISK_MODEL}"

# ─── Safety Check ──────────────────────────────────────────────────────────
echo ""
log_warn "WARNING: This will FORMAT ${STORAGE_DISK} and ERASE ALL DATA!"
log_warn "Disk: ${STORAGE_DISK} (${DISK_SIZE_GB} GB — ${DISK_MODEL})"
confirm "Are you ABSOLUTELY sure you want to format this disk?" || bail "Aborting."
confirm "Type 'y' again to confirm destructive operation" || bail "Aborting."

# ─── Check if Mounted ──────────────────────────────────────────────────────
if mount | grep -q "$STORAGE_DISK"; then
  log_info "Unmounting existing partitions..."
  umount "${STORAGE_DISK}"* 2>/dev/null || true
fi

# ─── Partition ──────────────────────────────────────────────────────────────
log_info "Creating partition table..."
parted -s "$STORAGE_DISK" mklabel gpt
parted -s "$STORAGE_DISK" mkpart primary ext4 1MiB 100%
log_ok "Partition created."

# Determine partition name (sda1 or nvme0n1p1, etc.)
sleep 2  # Wait for kernel to detect
PARTITION="${STORAGE_DISK}1"
if [[ ! -b "$PARTITION" ]]; then
  PARTITION="${STORAGE_DISK}p1"
fi
[[ -b "$PARTITION" ]] || bail "Could not find partition after creation."

# ─── Format ─────────────────────────────────────────────────────────────────
log_info "Formatting ${PARTITION} as ext4..."
mkfs.ext4 -L depin-storage -m 1 "$PARTITION"
log_ok "Formatted as ext4."

# ─── Mount ──────────────────────────────────────────────────────────────────
log_info "Creating mount point ${STORAGE_MOUNT}..."
mkdir -p "$STORAGE_MOUNT"

log_info "Mounting ${PARTITION} to ${STORAGE_MOUNT}..."
mount "$PARTITION" "$STORAGE_MOUNT"
log_ok "Mounted."

# ─── fstab Entry ────────────────────────────────────────────────────────────
PART_UUID=$(blkid -s UUID -o value "$PARTITION")
log_info "Partition UUID: ${PART_UUID}"

# Remove old entry if exists
sed -i "\|${STORAGE_MOUNT}|d" /etc/fstab

# Add new entry — nofail so the system boots even if the drive is disconnected
echo "UUID=${PART_UUID}  ${STORAGE_MOUNT}  ext4  defaults,nofail,noatime  0  2" >> /etc/fstab
log_ok "Added to /etc/fstab with nofail."

# Verify fstab is valid
mount -a 2>/dev/null
log_ok "fstab validated."

# ─── Create DePIN Data Directory ───────────────────────────────────────────
DEPIN_DATA="${STORAGE_MOUNT}/data"
mkdir -p "$DEPIN_DATA"
chown -R "${SSH_USER}:${SSH_USER}" "$DEPIN_DATA" 2>/dev/null || true
chmod 755 "$DEPIN_DATA"

# ─── Calculate Allocation ──────────────────────────────────────────────────
TOTAL_BYTES=$(df -B1 "$STORAGE_MOUNT" | awk 'NR==2 {print $2}')
TOTAL_GB=$((TOTAL_BYTES / 1073741824))
ALLOC_GB=$(( TOTAL_GB * STORAGE_ALLOC_PERCENT / 100 ))

log_info "Total disk: ${TOTAL_GB} GB"
log_info "DePIN allocation (${STORAGE_ALLOC_PERCENT}%): ${ALLOC_GB} GB"

# ─── SMART Health Check ───────────────────────────────────────────────────
log_info "Running SMART health check..."
if smartctl -H "$STORAGE_DISK" &>/dev/null; then
  SMART_STATUS=$(smartctl -H "$STORAGE_DISK" | grep -i "overall" || echo "Unknown")
  log_info "SMART status: ${SMART_STATUS}"

  # Enable SMART monitoring
  smartctl -s on "$STORAGE_DISK" 2>/dev/null || true

  # Schedule short self-test
  smartctl -t short "$STORAGE_DISK" 2>/dev/null || true
  log_ok "SMART monitoring enabled."
else
  log_warn "SMART not supported on this drive (common for USB-attached drives)."
fi

# ─── Create Health Check Script ────────────────────────────────────────────
cat > /usr/local/bin/depin-storage-health <<'HEALTH_EOF'
#!/usr/bin/env bash
# Quick storage health check
echo "=== DePIN Storage Health ==="
echo "Mount point: /mnt/depin-storage"
df -h /mnt/depin-storage
echo ""
echo "I/O stats:"
iostat -d $(basename $(findmnt -n -o SOURCE /mnt/depin-storage)) 2>/dev/null || echo "iostat not available"
echo ""
echo "SMART status:"
smartctl -H /dev/sda 2>/dev/null || echo "SMART not available"
HEALTH_EOF
chmod +x /usr/local/bin/depin-storage-health

# ─── Cron: Weekly SMART Check ──────────────────────────────────────────────
(crontab -l 2>/dev/null; echo "0 3 * * 0 smartctl -t long ${STORAGE_DISK} 2>/dev/null") | sort -u | crontab -
log_ok "Weekly SMART long test scheduled (Sunday 3 AM)."

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "=== Storage Preparation Complete ==="
echo ""
df -h "$STORAGE_MOUNT"
echo ""
log_info "Mount: ${STORAGE_MOUNT}"
log_info "Data dir: ${DEPIN_DATA}"
log_info "Allocation: ${ALLOC_GB} GB (${STORAGE_ALLOC_PERCENT}% of ${TOTAL_GB} GB)"
log_info "fstab: Configured with nofail"
log_ok "Phase 7 complete. Next: deploy storage DePIN with 08-deploy-storage.sh"
