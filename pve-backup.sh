#!/bin/bash
# ==============================================================================
#  pve-backup.sh
#  Backs up all Proxmox VE host configuration to Proxmox Backup Server.
#
#  What gets backed up:
#    - All PVE config (VMs, CTs, storage, users, firewall, HA, replication)
#    - Network configuration
#    - SSH host keys (preserves fingerprint across reinstalls)
#    - Cron jobs and custom scripts
#    - LVM metadata for the VM storage array
#    - PERC H730 RAID config (if perccli is installed)
#    - Package list and system information
#
#  What does NOT get backed up:
#    - The OS disk itself  (reinstall PVE fresh on the new drive)
#    - VM disk contents    (handled by your existing PVE backup jobs in the UI)
#
#  Retention policy:
#    - Keep last 7 snapshots
#    - Keep 4 weekly snapshots
#    - Keep 3 monthly snapshots
#
#  INSTALL:
#    1. Fill in the CONFIG section below
#    2. Copy to your PVE host:
#         scp pve-backup.sh root@<pve-ip>:/usr/local/bin/
#    3. On the PVE host:
#         chmod +x /usr/local/bin/pve-backup.sh
#    4. Test it:
#         /usr/local/bin/pve-backup.sh
#    5. Schedule daily at 02:00:
#         echo "0 2 * * * root /usr/local/bin/pve-backup.sh" \
#           > /etc/cron.d/pve-backup
# ==============================================================================

# -- CONFIG --------------------------------------------------------------------

PBS_HOST="192.168.1.15"           # IP or hostname of your PBS server
PBS_DATASTORE="Backup1"           # Datastore name on PBS
PBS_TOKENID="root@pam!Backup"     # API token ID
PBS_TOKEN_SECRET="your-token-secret-here"  # API token secret
PBS_FINGERPRINT="your-pbs-fingerprint-here"  # PBS TLS fingerprint
#
# To get your PBS fingerprint, run this on your PBS server:
#   openssl s_client -connect <pbs-ip>:8007 2>/dev/null | \
#     openssl x509 -fingerprint -sha256 -noout | cut -d= -f2 | tr '[:upper:]' '[:lower:]'
#
# Or find it in PBS web UI: Administration -> Certificates
#
PBS_NAMESPACE=""                  # Leave empty for root namespace

# Retention policy
KEEP_LAST=7        # Keep the 7 most recent snapshots
KEEP_WEEKLY=4      # Keep 4 weekly snapshots
KEEP_MONTHLY=3     # Keep 3 monthly snapshots

# -- END CONFIG ----------------------------------------------------------------

set -eo pipefail

# Clear any leftover PBS credentials from the shell session
unset PBS_PASSWORD

BACKUP_ID="$(hostname)-host-config"
STAGING="/tmp/pve-backup-staging"
LOG="/var/log/pve-backup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

log "============================================================"
log "PVE backup starting on $(hostname)"
log "============================================================"

if [[ $EUID -ne 0 ]]; then
    log "ERROR: must be run as root"; exit 1
fi
if ! command -v proxmox-backup-client &>/dev/null; then
    log "ERROR: proxmox-backup-client not found"
    log "       Install with: apt install proxmox-backup-client"
    exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"

stage_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        mkdir -p "$STAGING$(dirname "$src")"
        cp -a "$src" "$STAGING$src"
        log "  + $src"
    fi
}

stage_dir() {
    local src="$1"
    if [[ -d "$src" ]]; then
        mkdir -p "$STAGING$src"
        cp -a "$src/." "$STAGING$src/"
        log "  + $src/"
    fi
}

# ------------------------------------------------------------------------------
log "--- PVE configuration ---"
stage_dir  /etc/pve
stage_dir  /var/lib/pve-cluster

log "--- Network ---"
stage_file /etc/network/interfaces
stage_dir  /etc/network/interfaces.d
stage_file /etc/hosts
stage_file /etc/hostname
stage_file /etc/resolv.conf

log "--- SSH host keys ---"
stage_dir  /etc/ssh

log "--- Cron jobs ---"
stage_dir  /etc/cron.d
stage_dir  /etc/cron.daily
stage_dir  /etc/cron.weekly
stage_dir  /etc/cron.monthly

log "--- Custom scripts ---"
stage_dir  /usr/local/sbin
stage_dir  /usr/local/bin

log "--- Root home directory ---"
stage_dir  /root

# ------------------------------------------------------------------------------
log "--- LVM metadata ---"
LVM_DIR="$STAGING/root/lvm-backup"
mkdir -p "$LVM_DIR"

pvs > "$LVM_DIR/pvs.txt" 2>/dev/null || true
vgs > "$LVM_DIR/vgs.txt" 2>/dev/null || true
lvs > "$LVM_DIR/lvs.txt" 2>/dev/null || true

mkdir -p "$LVM_DIR/vgcfgbackup"
vgcfgbackup -f "$LVM_DIR/vgcfgbackup/%s" 2>/dev/null || true

vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' \
    > "$LVM_DIR/vg-names.txt" || true

log "  VGs found: $(cat "$LVM_DIR/vg-names.txt" | tr '\n' ' ')"

# ------------------------------------------------------------------------------
log "--- PERC H730 RAID config ---"
RAID_DIR="$STAGING/root/raid-backup"
mkdir -p "$RAID_DIR"

PERCCLI=""
for candidate in \
    /opt/MegaRAID/perccli/perccli64 \
    /opt/MegaRAID/perccli/perccli \
    /usr/sbin/perccli64 \
    perccli64 perccli; do
    if command -v "$candidate" &>/dev/null || [[ -x "$candidate" ]]; then
        PERCCLI="$candidate"
        break
    fi
done

if [[ -n "$PERCCLI" ]]; then
    log "  Using: $PERCCLI"
    $PERCCLI /call show all      > "$RAID_DIR/perccli-all.txt"    2>/dev/null || true
    $PERCCLI /call/vall show all > "$RAID_DIR/perccli-vd-all.txt" 2>/dev/null || true
    $PERCCLI /call/pall show all > "$RAID_DIR/perccli-pd-all.txt" 2>/dev/null || true
else
    log "  perccli not found -- RAID config not captured"
    log "  (RAID config lives on the H730 controller itself -- this is fine)"
fi

# ------------------------------------------------------------------------------
log "--- System information ---"
SYS_DIR="$STAGING/root/system-backup"
mkdir -p "$SYS_DIR"

pveversion              > "$SYS_DIR/pveversion.txt"      2>/dev/null || true
dpkg --get-selections   > "$SYS_DIR/dpkg-selections.txt" 2>/dev/null || true
apt-mark showmanual     > "$SYS_DIR/apt-manual.txt"      2>/dev/null || true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL \
                        > "$SYS_DIR/lsblk.txt"           2>/dev/null || true

cat > "$SYS_DIR/backup-info.txt" <<EOF
Date        : $(date)
Hostname    : $(hostname)
PVE version : $(pveversion 2>/dev/null | head -1 || echo unknown)
Kernel      : $(uname -r)
IP addresses: $(ip -br addr | awk '$2=="UP"{print $1,$3}' | tr '\n' '  ')
PBS host    : $PBS_HOST
Datastore   : $PBS_DATASTORE
Backup ID   : $BACKUP_ID
EOF

# ------------------------------------------------------------------------------
log "--- Sending to PBS ---"
log "  Host      : $PBS_HOST"
log "  Datastore : $PBS_DATASTORE"
log "  Token     : $PBS_TOKENID"
log "  Backup ID : $BACKUP_ID"

PBS_REPO="${PBS_TOKENID}@${PBS_HOST}:${PBS_DATASTORE}"

# proxmox-backup-client reads credentials from PBS_PASSWORD (even for tokens)
# and the TLS fingerprint from PBS_FINGERPRINT to avoid interactive prompts
export PBS_PASSWORD="$PBS_TOKEN_SECRET"
export PBS_FINGERPRINT

NS_FLAG=""
if [[ -n "$PBS_NAMESPACE" ]]; then
    NS_FLAG="--ns $PBS_NAMESPACE"
fi

proxmox-backup-client backup \
    "host-config.pxar:${STAGING}" \
    --repository "$PBS_REPO" \
    --backup-type host \
    --backup-id "$BACKUP_ID" \
    $NS_FLAG \
    | tee -a "$LOG"

# ------------------------------------------------------------------------------
log "--- Applying retention policy ---"
log "  Keep last    : $KEEP_LAST"
log "  Keep weekly  : $KEEP_WEEKLY"
log "  Keep monthly : $KEEP_MONTHLY"

proxmox-backup-client prune "host/${BACKUP_ID}" \
    --repository "$PBS_REPO" \
    --keep-last "$KEEP_LAST" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    $NS_FLAG \
    | tee -a "$LOG"

log "============================================================"
log "Backup and prune complete"
log "============================================================"
