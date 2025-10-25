#!/bin/bash
# ============================================================
# Proxmox Backup Client Script – keeps last 3 backups
# Token is included directly in the script
# ============================================================

# Configuration
TOKEN_USER="root@pam!cronbackup" 
#TOKEN_USER="root@pam!cronbackup"
#What it is: This is the Proxmox Backup Server (PBS) API token identifier.
#Format: username@realm!tokenid
#root@pam → the user on the PBS (root user in the PAM authentication realm).
#cronbackup → the name of the token you created for automated backups.
#Where it comes from: You create this token on the PBS web interface under:
#Datacenter → Access Control → API Tokens → Add

TOKEN_SECRET="Your Token" 
#What it is: The secret key for the token.
#Purpose: Acts like a password for the token. The proxmox-backup-client uses it to authenticate without entering a password interactively.
#Where it comes from: Displayed when you create the token on PBS. You must copy it immediately, because PBS only shows it once.

REPO_SERVER="192.168.1.15:Datastore1"
#What it is: The address of your Proxmox Backup Server repository.
#Format: IP_or_hostname:DatastoreName
#192.168.1.15 → IP of your PBS
#Datastore1 → name of the datastore on PBS where backups are stored
#Where it comes from: Defined when you set up a datastore on PBS (Datacenter → Datastore → Add).

BACKUP_NAME="pve"
LOGFILE="/var/log/proxmox-backup.log"

# Set token secret for authentication
export PBS_PASSWORD="$TOKEN_SECRET"

# Derived settings
HOSTNAME=$(hostname)
BACKUP_GROUP="host/$HOSTNAME"

# Timestamp
echo "========== $(date '+%Y-%m-%d %H:%M:%S') ==========" >> "$LOGFILE"

# Run backup
echo "Starting backup..." >> "$LOGFILE"
proxmox-backup-client backup \
    ${BACKUP_NAME}-etc.pxar:/etc \
    --include-dev /etc/pve \
    ${BACKUP_NAME}-root.pxar:/root \
    --repository "$TOKEN_USER@$REPO_SERVER" >> "$LOGFILE" 2>&1

# Prune old backups if successful
if [ $? -eq 0 ]; then
    echo "Backup succeeded, pruning old backups..." >> "$LOGFILE"
    proxmox-backup-client prune "$BACKUP_GROUP" \
        --repository "$TOKEN_USER@$REPO_SERVER" \
        --keep-last 3 >> "$LOGFILE" 2>&1
else
    echo "Backup failed, skipping prune." >> "$LOGFILE"
fi

echo "Done." >> "$LOGFILE"
echo "" >> "$LOGFILE"
