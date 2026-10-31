# Raspberry Pi 5 NAS Setup Guide
## Raspberry Pi OS Lite + USB HDD + Samba + Tailscale (including iOS Files support)

This guide builds a private NAS on a Raspberry Pi 5. It provides:
- Local network file sharing with Samba
- Secure remote access through Tailscale
- Read/write access from Windows, macOS, Linux, Android, and iPhone/iPad
- Apple SMB compatibility settings for the iOS Files app

> **Important:** Commands and examples assume a fresh Raspberry Pi OS Lite 64-bit installation, a Linux-formatted data drive, a Linux username of `nasadmin`, and a share mounted at `/srv/nas`. Replace example device names, UUIDs, hostnames, and IP addresses with your own values.
>
> **Data safety:** Formatting a drive erases data. Do not run the formatting command unless you have verified the correct drive and backed up anything you need.

---

## 1. Hardware

You need:
- Raspberry Pi 5 and suitable USB-C power supply
- microSD card (32 GB or larger recommended)
- External USB HDD (use its own power adapter if required)
- Ethernet cable to your router (recommended)
- Another computer to prepare the microSD card

For a bus-powered 2.5-inch HDD, confirm the Pi can power it reliably. A powered USB hub may be needed.

## 2. Install Raspberry Pi OS Lite

1. Download and install Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
2. Select **Raspberry Pi 5**.
3. Select **Raspberry Pi OS Lite (64-bit)**.
4. Select the microSD card.
5. In OS customisation, set:
   - Hostname: `pinas`
   - Username: `nasadmin`
   - A strong, unique password
   - Time zone: `Asia/Kolkata` (change if needed)
   - Enable SSH
   - Configure Wi-Fi only if not using Ethernet
6. Write the image to the microSD card.
7. Insert the card into the Pi, connect Ethernet to the router, connect the HDD, and power on.
8. Wait a few minutes for first boot.

From a Mac or Linux terminal, or Windows PowerShell, connect with:

```bash
ssh nasadmin@pinas.local
```

If hostname resolution fails, find the Pi's IP address in the router's connected-device list and use:

```bash
ssh nasadmin@192.168.1.100
```

Replace the example IP with the Pi's actual IP address.

Update the system:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Reconnect over SSH after the reboot.

## 3. Identify and prepare the external HDD

Identify devices and filesystems:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL
```

Identify the HDD by its model and capacity. Do **not** assume it is `/dev/sda1`.

### 3.1 If the drive can be erased and you want ext4

**Only after confirming the correct partition and backing up any needed files**, format the partition. Replace `/dev/sda1` with the actual HDD partition:

```bash
sudo mkfs.ext4 -L NASDATA /dev/sda1
```

If the drive contains files you want to keep, do not format it. Identify its existing filesystem first and use an appropriate mount configuration.

### 3.2 Create the mount point and get the UUID

```bash
sudo mkdir -p /srv/nas
sudo blkid
```

Copy the UUID for the HDD partition, not the microSD card.

Back up the mount configuration:

```bash
sudo cp /etc/fstab /etc/fstab.backup
sudo nano /etc/fstab
```

Add a line at the bottom, replacing the example UUID with your HDD's actual UUID:

```fstab
UUID=REPLACE-WITH-HDD-UUID /srv/nas ext4 defaults,nofail 0 2
```

Save (`Ctrl+O`, Enter) and exit (`Ctrl+X`).

Check the mount before rebooting:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt /srv/nas
df -h /srv/nas
```

If the mount command reports an error, correct it before rebooting. The example `fstab` entry is for ext4; other filesystems require different options.

## 4. Set up folders and permissions

The following assumes the filesystem is mounted at `/srv/nas` and the Linux account is `nasadmin`.

```bash
sudo chown nasadmin:nasadmin /srv/nas
sudo chmod 2770 /srv/nas
mkdir -p /srv/nas/Shared /srv/nas/Backups /srv/nas/Media
```

These directories will be available inside the Samba share. The `2770` mode gives the owner and group access and enables group inheritance. Do not use `chmod -R 777`.

## 5. Install and configure Samba

Install Samba and the Apple compatibility VFS modules:

```bash
sudo apt install samba samba-common-bin samba-vfs-modules attr -y
```

Set a Samba password (it can be different from the Linux login password):

```bash
sudo smbpasswd -a nasadmin
sudo smbpasswd -e nasadmin
```

Back up the configuration and open it:

```bash
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
sudo nano /etc/samba/smb.conf
```

### 5.1 Add Apple/iOS-compatible global settings

In the existing `[global]` section, add or merge the following settings. Keep other existing global settings. Ensure there is only **one effective `vfs objects` line** in the `[global]` section; if one already exists, replace/merge it rather than creating a duplicate.

```ini
[global]
   min protocol = SMB2
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
```

These Apple-specific Samba `fruit` settings, together with `streams_xattr`, resolved an iOS Files app write failure (`OSStatus error -61`) in the setup this guide is based on. Behaviour can vary by Samba and iOS version, so treat this as a tested configuration rather than a universal guarantee.

### 5.2 Add the NAS share

At the end of `smb.conf`, add:

```ini
[NAS]
   comment = Raspberry Pi NAS Storage
   path = /srv/nas
   browseable = yes
   read only = no
   guest ok = no
   valid users = nasadmin
   create mask = 0660
   directory mask = 2770
```

Save and exit.

### 5.3 Validate and start Samba

```bash
sudo testparm
sudo systemctl enable --now smbd
sudo systemctl restart smbd
sudo systemctl status smbd --no-pager
```

Check that the service is `active (running)` and that `testparm` reports no configuration errors.

## 6. Test Linux extended attributes

The `streams_xattr` VFS module uses extended attributes. Install the tools and run a small test on the mounted HDD:

```bash
sudo apt install attr -y
sudo touch /srv/nas/xattr_test
sudo setfattr -n user.test -v hello /srv/nas/xattr_test
getfattr -d /srv/nas/xattr_test
sudo rm /srv/nas/xattr_test
```

Expected output from `getfattr` includes:

```text
user.test="hello"
```

If `setfattr` reports an error, investigate filesystem support and mount options before proceeding. Because the test uses `sudo` for `setfattr`, it confirms root can set an attribute; it does not by itself prove all attributes work as the Samba user.

## 7. Install and connect Tailscale

Install Tailscale using its official Linux installation instructions: <https://tailscale.com/download/linux>

The standard install command for supported Debian-based Raspberry Pi OS versions is:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Bring the Pi onto your Tailscale network:

```bash
sudo tailscale up
```

Open the authentication URL shown in the terminal and authorise the Pi.

Get the Pi's Tailscale IPv4 address:

```bash
tailscale ip -4
tailscale status
```

Install Tailscale on each client device and sign in to the same tailnet:
- Windows/macOS/Linux: <https://tailscale.com/download>
- iPhone/iPad/Android: install the official Tailscale app from the device's app store or Tailscale download page.

Do not forward SMB ports 445 or 139 from your router to the internet. Use Tailscale for remote access.

## 8. Connect from client devices

### Windows (local or remote through Tailscale)

In File Explorer's address bar:

```text
\\192.168.1.100\NAS
```

Use the Pi's actual LAN IP address while at home. Use its Tailscale IP when away from home, for example:

```text
\\100.x.y.z\NAS
```

Log in as the Samba user `nasadmin` with the Samba password.

### macOS (local or remote through Tailscale)

In Finder, press `Command+K`, then enter:

```text
smb://192.168.1.100/NAS
```

When away from home, use the Pi's Tailscale IP instead.

### Linux

In a file manager that supports SMB, connect to:

```text
smb://192.168.1.100/NAS
```

Alternatively, use the Tailscale IP when remote.

### iPhone/iPad — Apple Files app

1. Enable Tailscale on the iPhone/iPad when connecting from outside your home network.
2. Open **Files** → **Browse**.
3. Tap the `…` menu → **Connect to Server**.
4. Enter the server address using the Pi's Tailscale IP, for example:

   ```text
   smb://100.x.y.z
   ```

   On the home network, the LAN IP can be used instead.
5. Select **Registered User**, not Guest.
6. Enter username `nasadmin` and the Samba password.
7. Open the `NAS` share and test creating a folder and uploading a small file.

If iOS Files shows a write error, verify that the Apple-compatible global Samba settings in Section 5.1 are present and active, especially:

```ini
vfs objects = catia fruit streams_xattr
```

Then validate and restart Samba:

```bash
sudo testparm
sudo systemctl restart smbd
```

On the iPhone, eject/disconnect the server in Files and reconnect as a Registered User.

## 9. Make the setup reliable

### Reserve the Pi's LAN IP address

In the home router's DHCP/address reservation settings, reserve the Pi's current LAN IP address. This keeps local SMB connections consistent. Tailscale connections should use the Pi's Tailscale IP.

### Verify services and the HDD after reboot

```bash
sudo reboot
```

After the Pi restarts, reconnect and run:

```bash
findmnt /srv/nas
df -h /srv/nas
systemctl is-active smbd
systemctl is-active tailscaled
```

Confirm that the HDD is mounted at `/srv/nas` and both services are active. If the drive is not mounted, do not copy files into `/srv/nas`; they could otherwise be written to the microSD card.

### Back up important files

A NAS is not a backup by itself. Keep a separate copy of important files on another physical drive or a trusted cloud service, and periodically test restoring files.

## 10. Troubleshooting commands

Check Samba configuration:

```bash
sudo testparm -s
```

Check the mount:

```bash
findmnt /srv/nas
lsblk -f
```

Check services:

```bash
sudo systemctl status smbd --no-pager
sudo systemctl status tailscaled --no-pager
```

Review recent logs:

```bash
sudo journalctl -u smbd -n 100 --no-pager
sudo journalctl -u tailscaled -n 100 --no-pager
```

If the HDD is not mounted, resolve that before changing Samba permissions. Avoid `chmod -R 777` and do not expose SMB ports to the public internet.

## Final checklist

- [ ] Raspberry Pi OS Lite installed and SSH works
- [ ] HDD mounted persistently at `/srv/nas`
- [ ] Samba share `NAS` works with username/password
- [ ] Apple `catia fruit streams_xattr` settings are active
- [ ] Extended-attribute test succeeds
- [ ] Tailscale connects the Pi and client devices
- [ ] Read/write tested from Windows, macOS, Linux, and iPhone/iPad
- [ ] No SMB ports forwarded from the router
- [ ] Separate backup plan in place

---

**Useful official references**
- Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
- Raspberry Pi Connect (optional administration): <https://www.raspberrypi.com/documentation/services/connect.html>
- Tailscale Linux install: <https://tailscale.com/download/linux>
- Tailscale NAS guide: <https://tailscale.com/docs/use-cases/personal-or-at-home-use/access-nas-media-file-servers>
- Apple iPhone server connection guide: <https://support.apple.com/en-in/guide/iphone/iphe9aff429a>
