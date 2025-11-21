#!/bin/bash
# ============================================================
# Proxmox Host Restore Script (Automatic)
# Restores /etc and /root from PBS backups using pxar archives
# ============================================================

### --- CONFIGURATION --- ###
PBS_REPO_USER="root@pam!cronbackup"
PBS_REPO_SERVER="192.168.1.15"
PBS_REPO_DATASTORE="Datastore1"
PBS_TOKEN_SECRET="YOUR TOKEN SECRET HERE"   # Required

### --- SETUP --- ###
export PBS_PASSWORD="$PBS_TOKEN_SECRET"

REPO="${PBS_REPO_USER}@${PBS_REPO_SERVER}:${PBS_REPO_DATASTORE}"

echo "======================================="
echo "   Proxmox PVE Host Restore Script"
echo "======================================="
echo ""
echo "Using repository: $REPO"
echo ""

# ------------------------------------------------------------
# Step 1: Install proxmox-backup-client (if missing)
# ------------------------------------------------------------
if ! command -v proxmox-backup-client >/dev/null 2>&1; then
    echo "[INFO] Installing proxmox-backup-client..."
    apt update && apt install -y proxmox-backup-client
fi

# ------------------------------------------------------------
# Step 2: Detect backup group automatically
# ------------------------------------------------------------
echo "[INFO] Finding backup groups..."
GROUP=$(proxmox-backup-client snapshots --repository "$REPO" | grep "host/" | awk '{print $1}' | head -n 1)

if [ -z "$GROUP" ]; then
    echo "[ERROR] No host backups found in repository!"
    exit 1
fi

echo "[INFO] Found backup group: $GROUP"

# ------------------------------------------------------------
# Step 3: Detect the latest snapshot
# ------------------------------------------------------------
LATEST=$(proxmox-backup-client snapshots "$GROUP" --repository "$REPO" | tail -n 1 | awk '{print $2}')

if [ -z "$LATEST" ]; then
    echo "[ERROR] Could not determine latest snapshot!"
    exit 1
fi

echo "[INFO] Latest snapshot: $LATEST"
echo ""

# ------------------------------------------------------------
# Step 4: Confirm restore
# ------------------------------------------------------------
read -p "Proceed with restoring this snapshot? (yes/no): " CHOICE
if [[ "$CHOICE" != "yes" ]]; then
    echo "Aborting restore."
    exit 0
fi

echo ""
echo "[INFO] Restoring /etc (pve-etc.pxar)..."
proxmox-backup-client restore pve-etc.pxar / \
    --repository "$REPO" \
    --snapshot "$LATEST" \
    --target / \
    --allow-existing-dirs

echo ""
echo "[INFO] Restoring /root (pve-root.pxar)..."
proxmox-backup-client restore pve-root.pxar / \
    --repository "$REPO" \
    --snapshot "$LATEST" \
    --target / \
    --allow-existing-dirs

# ------------------------------------------------------------
# Step 5: Cluster warning
# ------------------------------------------------------------
if [ -f /etc/pve/corosync.conf ]; then
    echo ""
    echo "⚠️  WARNING: This backup contains a cluster configuration."
    echo "If this server is NOT supposed to be in a cluster:"
    echo "  rm /etc/pve/corosync.conf"
    echo ""
fi

# ------------------------------------------------------------
# Step 6: Ask to reboot
# ------------------------------------------------------------
read -p "Restore complete. Reboot now? (yes/no): " REBOOT
if [[ "$REBOOT" == "yes" ]]; then
    reboot
else
    echo "You must reboot manually to apply restored configuration."
fi

exit 0
