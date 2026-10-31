<h1 align="center">PiNAS Setup</h1>

<p align="center">
  <b>Turn a Raspberry Pi 5 and a USB drive into a home NAS in about 5 minutes,<br>
  using a guided terminal wizard. Includes working iPhone / iPad Files app support.</b>
</p>

<p align="center">
  <a href="https://github.com/YOUR-USERNAME/pinas-setup/actions/workflows/shellcheck.yml"><img alt="ShellCheck" src="https://github.com/YOUR-USERNAME/pinas-setup/actions/workflows/shellcheck.yml/badge.svg"></a>
  <a href="https://github.com/YOUR-USERNAME/pinas-setup/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/YOUR-USERNAME/pinas-setup"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-Raspberry%20Pi%20OS-c51a4a">
</p>

---

`pinas-setup.sh` is an interactive Bash script that finds your external drive, prepares it,
mounts it permanently and sets up a Samba share that Windows, macOS, Linux, Android and the
**iOS Files app** can read and write. It asks a few questions in simple menus, shows you a
summary, and only then changes anything. At the end it tests its own work.

<!-- Video walkthrough: add your YouTube link here, e.g.
[![Watch the video](https://img.youtube.com/vi/VIDEO_ID/maxresdefault.jpg)](https://youtu.be/VIDEO_ID)
-->

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What the wizard asks](#what-the-wizard-asks)
- [What it changes on your system](#what-it-changes-on-your-system)
- [Command-line options](#command-line-options)
- [Non-interactive mode](#non-interactive-mode)
- [Connecting to your NAS](#connecting-to-your-nas)
- [Remote access with Tailscale](#remote-access-with-tailscale)
- [Undo / uninstall](#undo--uninstall)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Prefer to do it by hand?](#prefer-to-do-it-by-hand)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Smart drive detection.** Lists only external drives by model and size. The microSD /
  system disk is detected and hidden, so you can't pick it by mistake.
- **Keep or format.** Mount a Linux drive with its data intact, or format it as ext4.
  FAT, exFAT and NTFS drives get a clear warning before anything happens.
- **Hard-to-miss erase guard.** Erasing a drive requires typing `ERASE`.
- **Mounted the right way.** Uses the UUID, `nofail` and a short device timeout, so a
  missing drive can never stop the Pi from booting.
- **microSD protection.** The empty mount folder is locked (`chattr +i`), so if the drive is
  unplugged, files can't silently land on the SD card instead.
- **iPhone / iPad ready.** Applies the Samba `catia fruit streams_xattr` settings that fix the
  iOS Files app write error (`OSStatus error -61`).
- **Safe config edits.** Every file is backed up first. Samba config is validated with
  `testparm` before it's installed, and changes are rolled back if the mount or Samba fails.
- **Re-runnable.** Run it again any time to reconfigure, add folders, or just check health.
  Nothing is duplicated.
- **Built-in health check.** Tests the mount, boot entry, Samba service, share, user write
  access, extended attributes, and a real SMB login.
- **Dry-run mode.** See every command and every file change before committing to anything.

## Requirements

| | |
|---|---|
| **Board** | Raspberry Pi 5 (other Pi models running Raspberry Pi OS should also work) |
| **OS** | Raspberry Pi OS Lite (64-bit), freshly installed, with SSH enabled |
| **Drive** | An external USB HDD/SSD or NVMe drive |
| **Network** | Internet access (to install Samba), Ethernet recommended |
| **Access** | A user with `sudo` rights |

No extra tools are needed: the menus use `whiptail`, which is already part of Raspberry Pi OS.

## Quick start

SSH into your Pi, then:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/KskRoyal/pinas-setup.git
cd pinas-setup

# 1. Preview: answer the questions, see exactly what would change, change nothing
sudo bash pinas-setup.sh --dry-run

# 2. Run it for real
sudo bash pinas-setup.sh
```

<details>
<summary><b>Without git (download a single file)</b></summary>

```bash
wget https://raw.githubusercontent.com/YOUR-USERNAME/pinas-setup/v1.0.0/pinas-setup.sh
less pinas-setup.sh          # read it first, it's a script that can format drives
sudo bash pinas-setup.sh
```

There's deliberately no `curl … | sudo bash` one-liner. A script that can erase disks
should be read before it's run.
</details>

When it finishes, the script offers to reboot. After the Pi is back, confirm everything
came up on its own:

```bash
sudo bash pinas-setup.sh --verify
```

**Menu keys:** `↑` `↓` move · `Space` ticks a checkbox · `Tab` jumps to the buttons ·
`Enter` confirms · `Esc` goes back. Quitting before the review screen changes nothing.

## What the wizard asks

1. **Which drive** to use (system disk hidden; *Rescan* if you plug it in late)
2. **Which partition**, and whether to **keep its data** or **format it as ext4**,
   or erase the whole disk and create a fresh partition
3. **Mount point** (default `/srv/nas`) and **drive label** (default `NASDATA`)
4. **Share name** (default `NAS`)
5. **Samba user** (defaults to you; it can also create a file-sharing-only account
   with no SSH login) and its **password**
6. **Folders** to create (Shared, Backups, Media, Documents, Photos, or your own)
7. **Options:** Apple/iOS compatibility, system upgrade, hostname
8. **Review screen**, then **Apply**

## What it changes on your system

| What | Change |
|---|---|
| `/etc/fstab` | Adds one marked block that mounts the drive by UUID |
| `/etc/samba/smb.conf` | Adds a marked block to `[global]` and a marked share section |
| `/etc/hosts`, hostname | Only if you choose a new hostname |
| Mount point (e.g. `/srv/nas`) | Created and locked with `chattr +i` while empty |
| User account | Only if you ask it to create a new one |
| Packages | `samba`, `samba-vfs-modules`, `smbclient`, `attr`, `parted` |
| `/etc/pinas/pinas.conf` | Your answers, used as defaults next time |
| `/var/log/pinas-setup.log` | Full log of every run |

Before any file is edited, a timestamped backup is saved next to it, for example
`/etc/fstab.pinas-setup-20261031-143000.bak`. Lines from earlier manual setups that would
clash are commented out with `# pinas-setup disabled:`, never deleted.

## Command-line options

| Option | What it does |
|---|---|
| *(none)* | Interactive wizard |
| `--dry-run` | Asks everything, then prints the commands and file diffs without running them |
| `--verify` | Runs the health checks only |
| `--config FILE` | Non-interactive mode, answers read from `FILE` |
| `--yes` | With `--config`: skip the review screen |
| `--text` | Plain text prompts instead of menus (for basic terminals) |
| `-V`, `--version` | Prints the version |
| `-h`, `--help` | Shows help and all config keys |

## Non-interactive mode

For rebuilding a Pi or automating installs, put the answers in a file
(see [`examples/pinas.conf.example`](examples/pinas.conf.example)):

```ini
ACTION=keep              # keep | format_part | wipe_disk
PART=/dev/sda1           # or PART_UUID=...
MOUNT_POINT=/srv/nas
SHARE_NAME=NAS
SMB_USER=nasadmin
FOLDERS="Shared Backups Media"
APPLE_COMPAT=yes
UPGRADE=no
SMB_PASSWORD_FILE=/root/smb-password
```

```bash
sudo bash pinas-setup.sh --config my-nas.conf
```

To format or wipe in this mode you must also add `CONFIRM_ERASE=<the exact device>`.
The config file is parsed as plain `KEY=value` lines and is never executed.

## Connecting to your NAS

Log in as your Samba user with the Samba password. The script prints your exact addresses
at the end.

| Device | Address |
|---|---|
| **Windows** | File Explorer address bar: `\\pinas.local\NAS` or `\\192.168.1.100\NAS` |
| **macOS** | Finder → `⌘K`: `smb://pinas.local/NAS` |
| **Linux** | File manager: `smb://pinas.local/NAS` |
| **iPhone / iPad** | Files → Browse → `…` → Connect to Server: `smb://192.168.1.100`, then choose **Registered User** |
| **Android** | Any SMB-capable file manager, using the same address |

Tip: reserve the Pi's IP address in your router's DHCP settings so it never changes.

## Remote access with Tailscale

The script sets up local network sharing only. For secure access from anywhere,
install [Tailscale](https://tailscale.com/download/linux) on the Pi and your devices, then
connect using the Pi's Tailscale IP (`tailscale ip -4`). Full steps are in
[section 7 of the manual guide](docs/manual-setup.md#7-install-and-connect-tailscale).

> [!WARNING]
> Never forward SMB ports 445 or 139 on your router. Use Tailscale (or another VPN) instead.

## Undo / uninstall

The data on your drive is never touched by these steps.

```bash
sudo systemctl disable --now smbd
sudo umount /srv/nas
sudo chattr -i /srv/nas

# Restore the oldest backups = the files as they were before the first run
sudo cp "$(ls /etc/fstab.pinas-setup-*.bak | head -n1)" /etc/fstab
sudo cp "$(ls /etc/samba/smb.conf.pinas-setup-*.bak | head -n1)" /etc/samba/smb.conf
sudo systemctl daemon-reload
sudo rm -rf /etc/pinas

# Optional: remove Samba completely
sudo apt purge -y samba samba-vfs-modules
```

Replace `/srv/nas` if you chose a different mount point.

## Troubleshooting

<details>
<summary><b><code>$'\r': command not found</code> when running the script</b></summary>

The file was opened and saved on Windows, which changed its line endings. Fix it with:

```bash
sed -i 's/\r$//' pinas-setup.sh
```
</details>

<details>
<summary><b>"No external drive was detected"</b></summary>

Check the drive has power (2.5" drives may need a powered USB hub on the Pi), wait a few
seconds after plugging it in, then choose **Rescan**. `lsblk` should list it.
</details>

<details>
<summary><b>The script stopped with an error</b></summary>

It names the step that failed. Config files it was editing are restored automatically. The
full log is at `/var/log/pinas-setup.log`. Please attach it when opening an issue.
</details>

<details>
<summary><b>iPhone Files app shows error -61 when saving</b></summary>

Make sure *Apple / iOS compatibility* was enabled, then run `sudo bash pinas-setup.sh --verify`.
The "extended attributes" check must pass. On the iPhone, disconnect the server in Files and
reconnect as **Registered User**.
</details>

<details>
<summary><b>A check fails after reboot</b></summary>

Run `sudo bash pinas-setup.sh --verify` and look at which line failed. If the drive isn't
mounted, check its power and cable first, then `sudo mount -a`.
</details>

## FAQ

**Will it erase my drive?**
Only if you choose *Format* or *Erase*, confirm on the review screen, and then type `ERASE`.
Choose *Keep* to use a Linux drive with its data intact.

**Can I use an exFAT or NTFS drive with my existing files?**
Not reliably. These filesystems don't support the Linux extended attributes Samba's Apple
settings rely on, which leads to the iOS -61 error. Copy your files off, let the script format
the drive as ext4, then copy them back over the network.

**Why not OpenMediaVault or CasaOS?**
They're full NAS platforms with a web interface and many more moving parts. This script sets up
plain Samba with almost no overhead, and every change it makes is visible, logged and
reversible. Pick whichever suits you.

**Is it safe to run twice?**
Yes. On a second run it offers a health check or the wizard again with your previous answers
pre-filled. Config blocks are replaced, never duplicated.

**Does it set up Tailscale?**
No, see [Remote access with Tailscale](#remote-access-with-tailscale).

## Prefer to do it by hand?

[`docs/manual-setup.md`](docs/manual-setup.md) walks through every command the script automates,
with an explanation of each step: drive, fstab, permissions, Samba, the iOS fix and Tailscale.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
When reporting a problem, include your Pi model, OS version (`cat /etc/os-release`) and the
log file.

## License

[MIT](LICENSE). Use it, change it, share it.

> [!CAUTION]
> This script partitions, formats and mounts drives. Always keep a separate backup of
> important data. A NAS on its own is not a backup.
