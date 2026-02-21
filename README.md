# PVE Host Backup & Restore

## The Story

My name is Ole. I spent years as a VMware sysadmin, and when I decided to build my own homelab I naturally gravitated toward virtualisation. These days I run a Dell PowerEdge R730xd with 24TB of storage as my Proxmox VE host, and a Dell PowerEdge T320 with 16TB dedicated as my Proxmox Backup Server.

Coming from VMware, I was used to having proper backup and restore procedures for the hypervisor itself — not just the VMs. Proxmox has excellent built-in tools for backing up VM disk contents to PBS, but I couldn't find a clean, automated solution for backing up the PVE host configuration itself. Things like VM definitions, storage config, users, firewall rules, network config and SSH keys. The stuff you need to rebuild a host from scratch.

The situation became real when I decided to migrate PVE off a 900GB SATA SSD onto a new 479GB RAID volume I'd built on my PERC H730 controller. I had 25TB of VM storage on a separate RAID array on the same controller that I didn't want to touch. I needed a way to back up everything on the running host, install PVE fresh on the new drive, and restore it all — including getting the LVM volume group on the 25TB array re-activated so all my VMs would just appear and be ready to start.

I sat down with Claude (Anthropic's AI assistant) and we worked through it systematically. It wasn't entirely smooth — we ran into real-world issues along the way:

- Windows line endings (`\r\n`) breaking the shebang line on first run
- PBS API token authentication quirks (`PBS_PASSWORD` is used for both passwords and token secrets in `proxmox-backup-client`)
- The PBS TLS fingerprint causing interactive prompts that hung the script
- The `proxmox-backup-client list` command returning `last-backup` as a unix timestamp rather than the formatted date string the restore command expects
- LVM detection failing because the PERC H730 presents the RAID array as a whole disk PV (no partition), which broke the `lsblk PKNAME` lookup
- NIC names changing from `eno1`/`eno2` to `nic0`/`nic1` on the new server, taking down networking after the first restore
- The `prune` command requiring the backup group as a positional argument (`host/pve-host-config`) rather than separate `--backup-type` and `--backup-id` flags

Each time something broke we diagnosed it, fixed it, and moved on. By the end we had scripts that had been proven in a real migration — not just tested in theory.

The result is what you're looking at now. Two scripts that handle the full backup and restore of a PVE host, designed around the reality of hardware RAID controllers, separate VM storage arrays, and the quirks of `proxmox-backup-client`.

---

## What gets backed up

| Item | Details |
|------|---------|
| PVE configuration | VM/CT definitions, storage config, users, permissions, firewall rules, HA config, replication jobs, scheduled backup jobs |
| Network config | `/etc/network/interfaces`, DNS |
| SSH host keys | Preserves server fingerprint across reinstalls |
| Cron jobs | All cron directories |
| Custom scripts | `/usr/local/sbin`, `/usr/local/bin` |
| Root home | `/root` directory |
| LVM metadata | VG/LV layout for the VM storage array |
| RAID config | PERC H730 virtual disk config via perccli (if installed) |
| System info | Package list, PVE version, disk layout |

**What does NOT get backed up:**
- The OS disk itself — you reinstall PVE fresh on the new drive
- VM disk contents — handle those with PVE's built-in backup jobs to PBS

---

## Retention policy

The backup script automatically prunes old snapshots after each run using the following policy:

| Rule | Value |
|------|-------|
| Keep last | 7 snapshots |
| Keep weekly | 4 snapshots |
| Keep monthly | 3 snapshots |

Since host config backups are tiny (a few MB), this gives a comfortable history without using meaningful space on the PBS datastore. The values can be changed in the CONFIG section at the top of `pve-backup.sh`.

---

## Requirements

- Proxmox VE host
- Proxmox Backup Server (separate server recommended)
- `proxmox-backup-client` installed on the PVE host:
  ```bash
  apt install proxmox-backup-client
  ```
- A PBS API token with `DatastoreBackup` permissions

---

## Setup

### 1. Create a PBS API token

In the PBS web UI:
- Go to **Configuration → Access → API Tokens**
- Create a token (e.g. `root@pam!Backup`)
- Copy the token secret — it is only shown once

In the PBS web UI:
- Go to **Datastore → your-datastore → Permissions**
- Add the token with the `DatastoreBackup` role

### 2. Get the PBS TLS fingerprint

Run this on your PBS server:
```bash
openssl s_client -connect <pbs-ip>:8007 2>/dev/null | \
  openssl x509 -fingerprint -sha256 -noout | \
  cut -d= -f2 | tr '[:upper:]' '[:lower:]'
```

Or find it in the PBS web UI under **Administration → Certificates**.

### 3. Configure pve-backup.sh

Edit the CONFIG section at the top of `pve-backup.sh`:

```bash
PBS_HOST="192.168.1.x"
PBS_DATASTORE="your-datastore"
PBS_TOKENID="root@pam!your-token"
PBS_TOKEN_SECRET="your-token-secret-here"
PBS_FINGERPRINT="your-pbs-fingerprint-here"
PBS_NAMESPACE=""

KEEP_LAST=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3
```

### 4. Install and test

```bash
scp pve-backup.sh root@<pve-ip>:/usr/local/bin/
ssh root@<pve-ip> "chmod +x /usr/local/bin/pve-backup.sh"
ssh root@<pve-ip> "/usr/local/bin/pve-backup.sh"
```

Verify a snapshot appears in your PBS web UI under the datastore.

### 5. Schedule daily backups

```bash
echo "0 2 * * * root /usr/local/bin/pve-backup.sh" > /etc/cron.d/pve-backup
```

---

## Restore procedure

### Step 1 — Before you start

- Run a final manual backup on the old host
- Shut down all VMs cleanly from the PVE UI
- Shut down the old PVE host

### Step 2 — Install fresh PVE

- Install Proxmox VE on the new OS drive
- Use the **same hostname** as the original host
- Connect the VM storage array to the new server

### Step 3 — Configure pve-restore.sh

Edit the CONFIG section at the top of `pve-restore.sh`:

```bash
PBS_HOST="192.168.1.x"
PBS_DATASTORE="your-datastore"
PBS_TOKENID="root@pam!your-token"
PBS_TOKEN_SECRET="your-token-secret-here"
PBS_FINGERPRINT="your-pbs-fingerprint-here"
PBS_NAMESPACE=""
BACKUP_ID="your-hostname-host-config"
```

### Step 4 — Run the restore

```bash
scp pve-restore.sh root@<new-pve-ip>:/root/
ssh root@<new-pve-ip> "chmod +x /root/pve-restore.sh && bash /root/pve-restore.sh"
```

The script will:
1. Auto-detect the VM storage array (looks for a VG that is not named `pve`)
2. Download the latest backup from PBS
3. Restore hostname, network config, SSH keys, PVE config, LVM
4. Ask before applying each step
5. Offer to reboot when complete

### Step 5 — After reboot

- Log into the PVE web UI
- VMs should appear as stopped — start them normally
- Storage should appear under **Datacenter → Storage**

---

## NIC name changes

NIC names often change between servers (e.g. `eno1` → `nic0`). The restore script shows you the backed-up network config and asks before applying it. If NIC names have changed:

1. Say **NO** when asked to restore network config
2. After the restore completes, fix the names manually:
   ```bash
   sed -i 's/eno1/nic0/g' /etc/network/interfaces
   sed -i 's/eno2/nic1/g' /etc/network/interfaces
   systemctl restart networking
   ```

Also verify bridge assignments in the PVE web UI after reboot:
- **Node → System → Network**
- Check that each bridge (`vmbr0`, `vmbr1` etc) has the correct NIC in "Bridge ports"
- If VMs have no network, they may need their network interface reassigned to the correct bridge in the VM hardware config

---

## Monitoring

Check the backup log:
```bash
tail -f /var/log/pve-backup.log
```

The restore log is saved to:
```bash
/root/pve-restore.log
```

---

## Notes on PERC H730 / hardware RAID

The RAID configuration is stored on the controller itself, not the OS. As long as you keep the same controller and drives, the VM storage array will appear automatically on the new host — no RAID rebuild needed.

The VM storage LVM volume group lives on the RAID array and just needs to be activated on the new host with `vgchange -ay`, which the restore script handles automatically.

The script detects the VM storage array by looking for any LVM volume group that is **not** named `pve`. The `pve` VG is always created fresh by the PVE installer on the OS drive and is never touched by the restore.

---

## File structure

```
pve-backup.sh    -- runs on the PVE host, backs up config to PBS
pve-restore.sh   -- runs on a fresh PVE install, restores config from PBS
README.md        -- this file
```

---

## Known quirks of proxmox-backup-client

Documented here because they cost time to figure out and are not obvious from the documentation:

- **Token authentication** — even when using an API token, the client reads the secret from the `PBS_PASSWORD` environment variable, not `PBS_TOKEN_SECRET`. Set `export PBS_PASSWORD="your-token-secret"`.

- **TLS fingerprint** — if the PBS server uses a self-signed certificate and `PBS_FINGERPRINT` is not set, the client will prompt interactively and hang in a script. Always set `export PBS_FINGERPRINT`.

- **Snapshot timestamps** — `proxmox-backup-client list --output-format json` returns `last-backup` as a unix timestamp. The restore command expects the snapshot in `YYYY-MM-DDTHH:MM:SSZ` format. Convert with `datetime.utcfromtimestamp(ts).strftime(...)` in Python.

- **Prune group argument** — `proxmox-backup-client prune` requires the backup group as a single positional argument in `type/id` format (e.g. `host/pve-host-config`). Unlike the `backup` command which takes `--backup-type` and `--backup-id` as separate flags, `prune` will error with `missing argument` if you use that approach.

- **Line endings** — if the script was downloaded or edited on Windows, CRLF line endings will break the shebang line with `cannot execute: required file not found`. Fix with `sed -i 's/\r//' pve-backup.sh`.
