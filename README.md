# PVE Backup — Proxmox Backup Automation Script

A small, cron-friendly script to automate backing up critical configuration and home data from a Proxmox VE host to a Proxmox Backup Server (PBS). The script creates .pxar archives, uploads them to a PBS datastore, keeps the latest 3 backups, and logs all operations.

## Table of contents
- [Features](#features)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Usage](#usage)
- [Example directory / file structure](#example-directory--file-structure)
- [Notes & best practices](#notes--best-practices)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Features
- Back up /etc, /etc/pve and /root into .pxar archives
- Authenticate securely with PBS API token
- Upload backups to a specified PBS datastore
- Automatically prune older backups (keep last 3)
- Log all actions to a logfile for auditing and monitoring
- Designed for unattended operation (cron compatible)

## Requirements
- Proxmox VE host with access to PBS
- Proxmox Backup Server reachable from the VE host
- PBS API token with appropriate permissions (DatastoreBackup or DatastoreAdmin)
- pbs-client utilities (or whichever tools your script uses to create/upload .pxar archives)
- Bash (the script is written for a POSIX shell environment)

## Configuration variables
Set these variables in the script (or export them from a secure environment) before running:

- TOKEN_USER — PBS API token identifier, e.g. `root@pam!cronbackup`
- TOKEN_SECRET — API token secret, e.g. `12345678-9abc-def0-1234-56789abcdef0` (consider storing this in a separate file with restricted permissions)
- REPO_SERVER — PBS address and datastore, e.g. `192.168.1.15:Datastore1`
- BACKUP_NAME — Prefix used for backup files, e.g. `pve`
- LOGFILE — Log path, e.g. `/var/log/proxmox-backup.log`

## How it works
1. The script places the API token secret where PBS client tools can read it for authentication.
2. Creates .pxar archives of:
   - /etc
   - /etc/pve
   - /root
3. Uploads each backup to the configured PBS datastore.
4. Prunes older backups on the datastore, keeping only the last 3 per backup name.
5. Logs all operations (start, success/failure, prune results) to the logfile.

## Usage
1. Make the script executable:
   chmod +x /usr/local/sbin/proxmox-backup.sh

2. Run manually to test:
   /usr/local/sbin/proxmox-backup.sh

3. Add to root's crontab for daily backups at 03:00:
   0 3 * * * /usr/local/sbin/proxmox-backup.sh

Adjust schedule as needed.

## Example directory and backup file structure
- /var/log/proxmox-backup.log — Script log file
- /backups/ (local staging or example folder)
  - pve-etc.pxar — Current backup for /etc
  - pve-root.pxar — Current backup for /root
  - pve-etc-<timestamp>.pxar — Historical backups (managed and pruned by script)

Backups are stored on the PBS datastore as .pxar and pruned to the last 3 versions by the script.

## Notes & best practices
- Ensure the API token has only the permissions it needs (least privilege).
- For better security, store TOKEN_SECRET in a root-only readable file instead of embedding it in the script.
- Monitor /var/log/proxmox-backup.log and configure logrotate if necessary.
- Test restores occasionally to ensure backups are valid.

## Troubleshooting
- Authentication failures: verify TOKEN_USER and TOKEN_SECRET and token permissions.
- Connectivity issues: confirm the VE host can reach the PBS address and port.
- Upload failures: check available disk space and network stability.
- If script exits unexpectedly, consult the logfile for detailed error messages.

## License
Provided as-is. You may use, modify, and distribute this script freely. No warranty expressed or implied.
