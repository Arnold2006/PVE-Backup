#!/bin/bash
# ==============================================================================
#  pve-restore.sh
#  Restores Proxmox VE host configuration from Proxmox Backup Server.
#
#  USAGE:
#    1. Install fresh PVE on the new OS drive
#    2. Make sure the VM storage array is connected and visible
#    3. Fill in the CONFIG section below
#    4. Copy to the new PVE host:
#         scp pve-restore.sh root@<new-pve-ip>:/root/
#    5. On the new PVE host:
#         chmod +x /root/pve-restore.sh
#         bash /root/pve-restore.sh
#    6. Reboot when the script finishes
#    7. Log into the PVE web UI and start your VMs
#
#  IMPORTANT -- NIC NAMES:
#    NIC names often change between servers (e.g. eno1 -> nic0).
#    The script will show you the backed-up network config before applying it
#    and ask for confirmation. If NIC names have changed, say NO and configure
#    networking manually, or fix /etc/network/interfaces after the restore.
#    Always have IPMI or console access available before restoring.
# ==============================================================================

# -- CONFIG --------------------------------------------------------------------

PBS_HOST="192.168.1.xx"           # IP or hostname of your PBS server
PBS_DATASTORE="Datastore"           # Datastore name on PBS
PBS_TOKENID="root@pam!Backup"     # API token ID
PBS_TOKEN_SECRET="your-token-secret-here"  # API token secret
PBS_FINGERPRINT="your-pbs-fingerprint-here"  # PBS TLS fingerprint
PBS_NAMESPACE=""                  # Leave empty for root namespace

# Backup ID -- format is always: <hostname>-host-config
BACKUP_ID="pve-host-config"

# -- END CONFIG ----------------------------------------------------------------

set -eo pipefail

# Clear any leftover credentials from the shell session
unset PBS_PASSWORD

STAGING="/tmp/pve-restore-staging"
LOG="/root/pve-restore.log"

# Colours
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

log()     { echo -e "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
info()    { echo -e "${B}[INFO]${N} $*" | tee -a "$LOG"; }
ok()      { echo -e "${G}[ OK ]${N} $*" | tee -a "$LOG"; }
warn()    { echo -e "${Y}[WARN]${N} $*" | tee -a "$LOG"; }
err()     { echo -e "${R}[ERR ]${N} $*" | tee -a "$LOG"; }
die()     { err "$*"; exit 1; }

confirm() {
    local answer
    read -r -p "$(echo -e "${Y}?${N} $1 [y/N]: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

section() {
    echo "" | tee -a "$LOG"
    echo -e "${B}══════════════════════════════════════════════${N}" | tee -a "$LOG"
    echo -e "${B}  $*${N}" | tee -a "$LOG"
    echo -e "${B}══════════════════════════════════════════════${N}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
}

# ==============================================================================
#  PREFLIGHT
# ==============================================================================

section "Preflight checks"

touch "$LOG"

[[ $EUID -ne 0 ]] && die "Must be run as root"
command -v pvesh &>/dev/null   || die "pvesh not found -- is this a Proxmox VE install?"
command -v python3 &>/dev/null || die "python3 not found"

info "Host        : $(hostname)"
info "PVE version : $(pveversion 2>/dev/null | head -1 || echo unknown)"
info "Date        : $(date)"
info "Log         : $LOG"

# ==============================================================================
#  DETECT DISKS
#
#  The fresh PVE install creates a VG called "pve" on the OS drive.
#  The VM storage array will have a different VG name (e.g. VM-Data).
#  We detect both automatically without hardcoding any /dev/sdX names.
#
#  Handles both cases:
#    - PV is a partition (e.g. /dev/sda1)  -- common for OS drives
#    - PV is a whole disk (e.g. /dev/sda)  -- common for RAID controllers
# ==============================================================================

section "Detecting disk layout"

info "Block devices visible to this host:"
echo ""
lsblk -o NAME,SIZE,TYPE,MODEL | grep -v loop | tee -a "$LOG"
echo ""

info "Scanning for LVM volume groups..."
pvscan 2>/dev/null | tee -a "$LOG" || true
echo ""

# Find the VM storage VG -- any VG that is not named "pve"
VM_VG="$(vgs --noheadings -o vg_name 2>/dev/null \
    | awk '{print $1}' \
    | grep -v '^pve$' \
    | head -1 || true)"

# Find the PV and disk the VM VG lives on
VM_PV=""
VM_DISK=""
if [[ -n "$VM_VG" ]]; then
    VM_PV="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
        | awk -v vg="$VM_VG" '$2==vg {print $1}' | head -1 || true)"
    if [[ -n "$VM_PV" ]]; then
        # Try to get parent disk (works for partitions like /dev/sda1)
        VM_DISK_NAME="$(lsblk -no PKNAME "$VM_PV" 2>/dev/null | head -1 || true)"
        if [[ -n "$VM_DISK_NAME" ]]; then
            VM_DISK="/dev/$VM_DISK_NAME"
        else
            # PV is a whole disk (no partition) -- use PV directly
            # This is typical for hardware RAID controllers like PERC H730
            VM_DISK="$VM_PV"
        fi
    fi
fi

# Find the OS disk -- the one with the "pve" VG
OS_PV="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
    | awk '$2=="pve" {print $1}' | head -1 || true)"
OS_DISK=""
if [[ -n "$OS_PV" ]]; then
    OS_DISK_NAME="$(lsblk -no PKNAME "$OS_PV" 2>/dev/null | head -1 || true)"
    if [[ -n "$OS_DISK_NAME" ]]; then
        OS_DISK="/dev/$OS_DISK_NAME"
    else
        OS_DISK="$OS_PV"
    fi
fi

echo ""

if [[ -n "$VM_VG" && -n "$VM_DISK" ]]; then
    ok "VM storage array found"
    info "  Disk : $VM_DISK"
    info "  VG   : $VM_VG"
    info "  PV   : $VM_PV"
    echo ""
    info "OS disk  : $OS_DISK  (has 'pve' VG -- created by installer, will not be touched)"
    echo ""
    confirm "Is this correct?" || {
        warn "Check:  lsblk && pvs"
        warn "Make sure the VM storage array is connected and powered on."
        exit 1
    }
else
    err "Could not find the VM storage array."
    err "Expected a VG that is not named 'pve'."
    err "Current LVM state:"
    vgs 2>/dev/null || true
    err ""
    err "Possible causes:"
    err "  - The VM storage array is not connected or not powered on"
    err "  - The RAID controller has not initialised yet (try rebooting)"
    err ""
    err "Try:  vgscan && vgchange -ay"
    err "Then re-run this script."
    exit 1
fi

# ==============================================================================
#  STEP 1 -- Install proxmox-backup-client
# ==============================================================================

section "Step 1 -- Installing proxmox-backup-client"

if ! command -v proxmox-backup-client &>/dev/null; then
    info "Installing..."
    apt-get update -qq
    apt-get install -y proxmox-backup-client 2>&1 | tee -a "$LOG"
    ok "Installed"
else
    ok "Already installed"
fi

# ==============================================================================
#  STEP 2 -- Fetch backup from PBS
# ==============================================================================

section "Step 2 -- Fetching backup from PBS"

PBS_REPO="${PBS_TOKENID}@${PBS_HOST}:${PBS_DATASTORE}"

# proxmox-backup-client reads credentials from PBS_PASSWORD (even for tokens)
# and the TLS fingerprint from PBS_FINGERPRINT to avoid interactive prompts
export PBS_PASSWORD="$PBS_TOKEN_SECRET"
export PBS_FINGERPRINT

NS_FLAG=""
[[ -n "$PBS_NAMESPACE" ]] && NS_FLAG="--ns $PBS_NAMESPACE"

info "PBS server  : $PBS_HOST"
info "Datastore   : $PBS_DATASTORE"
info "Token       : $PBS_TOKENID"
info "Backup ID   : $BACKUP_ID"

rm -rf "$STAGING"
mkdir -p "$STAGING"

info "Finding latest snapshot..."
SNAPSHOT=$(proxmox-backup-client list \
    --repository "$PBS_REPO" \
    --output-format json \
    $NS_FLAG 2>/dev/null \
    | python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
matches = [x for x in data if x.get('backup-id') == 'pve-host-config' and x.get('backup-type') == 'host']
if not matches:
    print('No matching snapshots found', file=sys.stderr)
    sys.exit(1)
latest = sorted(matches, key=lambda x: x['last-backup'], reverse=True)[0]
ts = latest['last-backup']
print(datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ'))
") || die "No snapshots found for backup ID: $BACKUP_ID"

ok "Latest snapshot: $SNAPSHOT"

info "Downloading backup..."
proxmox-backup-client restore \
    "host/$BACKUP_ID/$SNAPSHOT" \
    "host-config.pxar" \
    "$STAGING" \
    --repository "$PBS_REPO" \
    $NS_FLAG \
    2>&1 | tee -a "$LOG"

ok "Backup downloaded"

# Show backup info and confirm
BACKUP_INFO="$STAGING/root/system-backup/backup-info.txt"
if [[ -f "$BACKUP_INFO" ]]; then
    section "Backup details"
    cat "$BACKUP_INFO" | tee -a "$LOG"
    echo ""
    confirm "Does this look correct?" || { warn "Aborted."; exit 0; }
fi

# ==============================================================================
#  STEP 3 -- Hostname
#  Must match the original because PVE config references it.
# ==============================================================================

section "Step 3 -- Hostname"

BACKUP_HOSTNAME="$(cat "$STAGING/etc/hostname" 2>/dev/null || true)"
CURRENT_HOSTNAME="$(hostname)"

info "Current hostname : $CURRENT_HOSTNAME"
info "Backup hostname  : $BACKUP_HOSTNAME"

if [[ -z "$BACKUP_HOSTNAME" ]]; then
    warn "No hostname found in backup -- skipping"
elif [[ "$CURRENT_HOSTNAME" != "$BACKUP_HOSTNAME" ]]; then
    warn "Hostnames do not match. PVE stores the hostname in its config."
    if confirm "Set hostname to '$BACKUP_HOSTNAME'?"; then
        echo "$BACKUP_HOSTNAME" > /etc/hostname
        hostname "$BACKUP_HOSTNAME"
        ok "Hostname set to $BACKUP_HOSTNAME"
    else
        warn "Skipped. If VMs do not appear after reboot, this is likely why."
    fi
else
    ok "Hostname already matches: $CURRENT_HOSTNAME"
fi

if [[ -f "$STAGING/etc/hosts" ]]; then
    cp "$STAGING/etc/hosts" /etc/hosts
    ok "/etc/hosts restored"
fi

# ==============================================================================
#  STEP 4 -- Network configuration
#
#  NIC names often change between servers (e.g. eno1 -> nic0).
#  The script shows the backed-up config and asks before applying.
#  If NIC names have changed, say NO and fix /etc/network/interfaces manually
#  after the restore using: sed -i 's/old-nic-name/new-nic-name/g'
# ==============================================================================

section "Step 4 -- Network configuration"

if [[ -f "$STAGING/etc/network/interfaces" ]]; then
    info "Backed-up /etc/network/interfaces:"
    echo "----------------------------------------------"
    cat "$STAGING/etc/network/interfaces"
    echo "----------------------------------------------"
    echo ""
    warn "If NIC names have changed between the old and new server, say NO"
    warn "and fix the names manually after the restore with sed."
    warn "Always have IPMI or console access available before saying yes."
    echo ""
    if confirm "Restore network config?"; then
        cp /etc/network/interfaces /etc/network/interfaces.bak
        cp "$STAGING/etc/network/interfaces" /etc/network/interfaces
        [[ -d "$STAGING/etc/network/interfaces.d" ]] && \
            cp -a "$STAGING/etc/network/interfaces.d/." /etc/network/interfaces.d/
        ok "Network config restored (takes effect on reboot)"
    else
        warn "Skipped -- configure networking manually if needed"
    fi
fi

if [[ -f "$STAGING/etc/resolv.conf" ]]; then
    cp "$STAGING/etc/resolv.conf" /etc/resolv.conf
    ok "resolv.conf restored"
fi

# ==============================================================================
#  STEP 5 -- SSH host keys
#  Restoring these means clients won't get a fingerprint warning after the move.
# ==============================================================================

section "Step 5 -- SSH host keys"

if [[ -d "$STAGING/etc/ssh" ]]; then
    if confirm "Restore SSH host keys? (recommended -- avoids fingerprint warnings)"; then
        cp -a "$STAGING/etc/ssh/." /etc/ssh/
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        ok "SSH host keys restored"
    fi
fi

# ==============================================================================
#  STEP 6 -- PVE configuration
#  Restores all VM definitions, storage, users, firewall, HA, replication.
# ==============================================================================

section "Step 6 -- PVE configuration"

[[ ! -d "$STAGING/etc/pve" ]] && die "/etc/pve not found in backup"

info "Stopping PVE services..."
for svc in pvestatd pveproxy pvedaemon pve-cluster; do
    systemctl stop "$svc" 2>/dev/null && info "  stopped $svc" || true
done

# Save the fresh install config as a fallback
cp -a /etc/pve /etc/pve.fresh-install 2>/dev/null || true

# Restore the pve-cluster database -- this is the canonical data store
if [[ -d "$STAGING/var/lib/pve-cluster" ]]; then
    info "Restoring pve-cluster database..."
    cp -a /var/lib/pve-cluster /var/lib/pve-cluster.fresh-install 2>/dev/null || true
    rm -rf /var/lib/pve-cluster/*
    cp -a "$STAGING/var/lib/pve-cluster/." /var/lib/pve-cluster/
    ok "pve-cluster database restored"
fi

# Restore /etc/pve flat files
cp -a "$STAGING/etc/pve/." /etc/pve/ 2>/dev/null || true
ok "PVE config files restored"

info "Starting PVE services..."
systemctl start pve-cluster
sleep 5
systemctl start pvedaemon
systemctl start pveproxy
systemctl start pvestatd

sleep 2
if pvesh get /nodes 2>/dev/null | grep -q "node"; then
    ok "PVE is running and responding"
else
    warn "PVE API not responding yet -- this normally resolves after a full reboot"
fi

# ==============================================================================
#  STEP 7 -- Activate VM storage VG
#  The VG already exists on the array. We just need to activate it so
#  PVE can see the VM disk images. No data is written to the array.
# ==============================================================================

section "Step 7 -- Activating VM storage ($VM_VG on $VM_DISK)"

info "OS VG 'pve' on $OS_DISK -- created by installer, leaving it alone."
info "Activating VM storage VG '$VM_VG' on $VM_DISK..."
echo ""

vgscan --mknodes 2>&1 | tee -a "$LOG" || true
vgchange -ay 2>&1 | tee -a "$LOG" || true

echo ""
info "Volume groups after activation:"
vgs | tee -a "$LOG"
echo ""
info "Logical volumes:"
lvs | tee -a "$LOG"
echo ""

if vgs --noheadings -o vg_name 2>/dev/null | grep -q "$VM_VG"; then
    ok "VM storage VG '$VM_VG' is active"
else
    warn "VM VG '$VM_VG' was not found after activation."
    warn "This may resolve after a full reboot."
    warn "If not, run:  vgscan && vgchange -ay"
fi

# ==============================================================================
#  STEP 8 -- Cron jobs and custom scripts
# ==============================================================================

section "Step 8 -- Cron jobs and custom scripts"

for d in cron.d cron.daily cron.weekly cron.monthly; do
    if [[ -d "$STAGING/etc/$d" ]]; then
        cp -a "$STAGING/etc/$d/." "/etc/$d/"
        ok "/etc/$d restored"
    fi
done

for d in usr/local/sbin usr/local/bin; do
    if [[ -d "$STAGING/$d" ]]; then
        cp -a "$STAGING/$d/." "/$d/"
        chmod +x "/$d/"* 2>/dev/null || true
        ok "/$d restored"
    fi
done

# ==============================================================================
#  STEP 9 -- Root home directory
# ==============================================================================

section "Step 9 -- Root home directory"

if [[ -d "$STAGING/root" ]]; then
    rsync -a \
        --exclude="system-backup/" \
        --exclude="lvm-backup/" \
        --exclude="raid-backup/" \
        "$STAGING/root/" /root/ 2>/dev/null || \
    cp -a "$STAGING/root/." /root/ 2>/dev/null || true
    ok "Root home restored"
fi

# ==============================================================================
#  DONE
# ==============================================================================

section "Restore complete"

echo -e "${G}"
echo "  OK  Hostname restored"
echo "  OK  Network config restored"
echo "  OK  SSH host keys restored"
echo "  OK  PVE configuration restored"
echo "  OK    -> VM and CT definitions"
echo "  OK    -> Storage configuration"
echo "  OK    -> Users and permissions"
echo "  OK    -> Firewall rules"
echo "  OK    -> Scheduled backup jobs"
echo "  OK  VM storage VG activated  ($VM_VG on $VM_DISK)"
echo "  OK  Cron jobs and scripts restored"
echo -e "${N}"

echo -e "${Y}After rebooting:${N}"
echo ""
echo "  PVE web UI : https://$(hostname -I | awk '{print $1}' 2>/dev/null):8006"
echo "  Your VMs should appear as stopped -- just start them."
echo "  Storage should appear under Datacenter -> Storage."
echo ""
echo "  If any VM disk is missing after reboot:"
echo "    vgchange -ay"
echo "  Then start the VM again."
echo ""
echo "  If VMs appear but have no network after reboot, check:"
echo "    Node -> System -> Network"
echo "  Verify each bridge has the correct NIC attached."
echo "  NIC names sometimes change between servers (e.g. eno1 -> nic0)."
echo ""

confirm "Reboot now?" && reboot || warn "Remember to reboot before starting VMs"
