Proxmox Backup Automation Script

This script automates backups of critical directories on a Proxmox VE host using Proxmox Backup Server (PBS). It is designed to run from cron and keeps the last 3 backups while logging all operations.

#Features:

Back up /etc, /etc/pve, and /root into .pxar archives

Authenticate securely using a PBS API token

Automatically prune older backups, keeping only the last 3

Logs all actions and results to /var/log/proxmox-backup.log

Fully cron-compatible for unattended operation

Configuration Variables

TOKEN_USER: PBS API token identifier, e.g., root@pam!cronbackup

TOKEN_SECRET: Secret key for the token, e.g., 12345678-9abc-def0-1234-56789abcdef0

REPO_SERVER: PBS address and datastore, e.g., 192.168.1.15:Datastore1

BACKUP_NAME: Prefix used for backup files, e.g., pve

LOGFILE: Path to the log file, e.g., /var/log/proxmox-backup.log

How It Works

Sets the API token secret for authentication with PBS

Creates .pxar backups of important directories (/etc, /etc/pve, /root)

Uploads the backups to the specified PBS datastore

Prunes older backups, keeping only the latest 3

Logs all output, including success or failure, for monitoring

Directory and Backup File Structure Example

/var/log/proxmox-backup.log → Script log file
/backups/

pve-etc.pxar → Backup of /etc

pve-root.pxar → Backup of /root

pve-etc.pxar_<timestamp>.pxar → Historical backups (managed by prune)

Usage

Make the script executable: chmod +x /usr/local/sbin/proxmox-backup.sh

Run manually to test: /usr/local/sbin/proxmox-backup.sh

Add a cron job for automated backups (daily at 3 AM):
0 3 * * * /usr/local/sbin/proxmox-backup.sh

Notes & Best Practices

Ensure the API token has sufficient privileges on the PBS datastore (DatastoreAdmin or DatastoreBackup)

Adjust BACKUP_NAME to match your naming convention

Review logs in /var/log/proxmox-backup.log for any errors

For enhanced security, you can store the token secret in a separate file instead of embedding it in the script

Diagram (Overview)

Proxmox VE Host → Proxmox Backup Server

/etc → Backup to Datastore1

/etc/pve → Backup to Datastore1

/root → Backup to Datastore1

Backup Script (cron-enabled) manages backups and pruning

Backups stored as .pxar files, pruned to last 3

License

This script is provided as-is. You may use, modify, and distribute it freely.
