# PVE Host Backup & Restore

Backup and restore scripts for Proxmox VE host configuration to Proxmox Backup Server (PBS).

Designed for setups where:
- PVE is installed on one drive (any `/dev/sdX`)
- VM storage lives on a separate drive or hardware RAID array (e.g. Dell PERC H730)
- PBS runs on a separate dedicated server

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
PBS_HOST="192.168.1.15"
PBS_DATASTORE="Backup1"
PBS_TOKENID="root@pam!Backup"
PBS_TOKEN_SECRET="your-token-secret-here"
PBS_FINGERPRINT="your-pbs-fingerprint-here"
PBS_NAMESPACE=""
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
PBS_HOST="192.168.1.15"
PBS_DATASTORE="Backup1"
PBS_TOKENID="root@pam!Backup"
PBS_TOKEN_SECRET="your-token-secret-here"
PBS_FINGERPRINT="your-pbs-fingerprint-here"
PBS_NAMESPACE=""
BACKUP_ID="pve-host-config"   # <-- change "pve" to your hostname
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
- If VMs have no network, they may need their network interface changed from one bridge to another in the VM's hardware config

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

The VM storage LVM volume group (e.g. `VM-Data`) lives on the RAID array and just needs to be activated on the new host with `vgchange -ay`, which the restore script handles automatically.

The script detects the VM storage array by looking for any LVM volume group that is **not** named `pve`. The `pve` VG is always created fresh by the PVE installer on the OS drive and is never touched by the restore.

---

## File structure

```
pve-backup.sh    -- runs on the PVE host, backs up config to PBS
pve-restore.sh   -- runs on a fresh PVE install, restores config from PBS
```
