Proxmox Backup Automation Script

This script automates backups of critical directories on a Proxmox VE host using Proxmox Backup Server (PBS). It is designed to be run from cron and keeps the last 3 backups while logging all operations.

Features
Back up /etc, /etc/pve, and /root into .pxar archives
Authenticate securely with a PBS API token
Automatically prune older backups, keeping only the last 3
Logs all actions and results to /var/log/proxmox-backup.log
Fully cron-compatible for unattended operation

Configuration Variables
Variable	Description	Example / Notes
TOKEN_USER	The PBS API token identifier	root@pam!cronbackup
TOKEN_SECRET	The secret key for the token	12345678-9abc-def0-1234-56789abcdef0
REPO_SERVER	The Proxmox Backup Server address and datastore	192.168.1.15:Datastore1
BACKUP_NAME	Prefix used for backup files	pve
LOGFILE	Path to the log file	/var/log/proxmox-backup.log

How It Works
Sets the API token secret for authentication with PBS
Creates .pxar backups of important directories (/etc, /etc/pve, /root)
Uploads the backups to the specified PBS datastore
Prunes older backups, keeping only the latest 3
Logs all output, including success or failure, for monitoring

Usage
Make the script executable:
chmod +x /usr/local/sbin/proxmox-backup.sh

Run manually to test:
/usr/local/sbin/proxmox-backup.sh

Add a cron job for daily automated backups (example: 3 AM):
crontab -e
# Add the line:
0 3 * * * /usr/local/sbin/proxmox-backup.sh

Notes
Make sure the token has sufficient privileges on the PBS datastore (DatastoreAdmin or DatastoreBackup)
Adjust BACKUP_NAME to match your naming convention for backup files

Logs can be reviewed in /var/log/proxmox-backup.log
