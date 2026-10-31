#!/usr/bin/env bash
# =============================================================================
#  pinas-setup.sh - interactive NAS setup wizard for Raspberry Pi OS (Pi 5)
#
#  Automates: drive detection -> (optional) format -> persistent mount ->
#             folders & permissions -> Samba (with Apple/iOS Files support)
#             -> verification.  Tailscale is intentionally not included.
#
#  Usage:
#    sudo bash pinas-setup.sh               interactive wizard (whiptail menus)
#    sudo bash pinas-setup.sh --dry-run     ask everything, change nothing,
#                                           show the commands and file diffs
#    sudo bash pinas-setup.sh --verify      only run the health checks
#    sudo bash pinas-setup.sh --config FILE non-interactive, answers from FILE
#    sudo bash pinas-setup.sh --help
#
#  Project: https://github.com/YOUR-USERNAME/pinas-setup   License: MIT
#
#  Safe to re-run: config edits live in marked blocks that are replaced, not
#  duplicated, and every edited file is backed up first.
# =============================================================================
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly PROG="${0##*/}"
readonly MARK="pinas-setup"
LOG_FILE="/var/log/pinas-setup.log"
STATE_DIR="/etc/pinas"
STATE_FILE="$STATE_DIR/pinas.conf"
BACKTITLE="Raspberry Pi NAS Setup  v$SCRIPT_VERSION"

# ----------------------------------------------------------------------------
# Settings (defaults; overwritten by saved state, a config file or the wizard)
# ----------------------------------------------------------------------------
DRY_RUN=0 ASSUME_YES=0 FORCE_TEXT=0 MODE="setup" CONFIG_FILE=""
DISK="" DISK_DESC="" PART="" PART_FS="" PART_UUID="" PART_SIZE="" PART_LABEL="" PART_MOUNT=""
ACTION=""                    # keep | format_part | wipe_disk
MOUNT_POINT="/srv/nas"
FS_LABEL="NASDATA"
SHARE_NAME="NAS"
SMB_USER=""
CREATE_USER="no"
SMB_PASSWORD="" SET_PASSWORD="no" SMB_PASSWORD_FILE=""
FOLDERS="Shared Backups Media"
APPLE_COMPAT="yes"
UPGRADE="yes"
NEW_HOSTNAME=""
FIX_OWNERSHIP="no"
CONFIRM_ERASE=""

PROTECTED_DISKS=()
CAND_DISKS=() CAND_DESCS=()
declare -A R=()
TMP=""
CURRENT_STEP="" STEP_NO=0 STEP_TOTAL=8
LAST_BACKUP=""
PI_MODEL="unknown"
USE_WT=0 WT_H=20 WT_W=76 WT_LIST=8 WT_MAX=22 WT_SCROLL=()
VERIFY_FAILS=0

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
fi

log()  { [[ -n ${LOG_FILE:-} && -w ${LOG_FILE:-/nonexistent} ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; return 0; }
say()  { printf '%s\n' "$*"; log "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; log "OK: $*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; log "WARN: $*"; }
err()  { printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; log "FAIL: $*"; }
die()  { err "$*"; exit 1; }

step() {
  STEP_NO=$((STEP_NO + 1)); CURRENT_STEP="$*"
  printf '\n%s[%d/%d] %s%s\n' "$C_B$C_C" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_0"
  log "=== STEP $STEP_NO/$STEP_TOTAL: $* ==="
}

# Run a command (or print it in dry-run mode); output goes to screen and log.
run() {
  log "+ $(printf '%q ' "$@")"
  if (( DRY_RUN )); then
    printf '  %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$(printf '%q ' "$@")"
    return 0
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

on_error() {
  local rc=$? line=$1
  printf '\n' >&2
  err "Stopped during: ${CURRENT_STEP:-setup} (line $line, exit code $rc)."
  err "Full log: $LOG_FILE"
  [[ -n $LAST_BACKUP ]] && err "Most recent config backup: $LAST_BACKUP"
  exit "$rc"
}

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; return 0; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

in_list() { local x=$1; shift; local y; for y in "$@"; do [[ $x == "$y" ]] && return 0; done; return 1; }

# ----------------------------------------------------------------------------
# UI layer: whiptail when available, plain prompts otherwise
# ----------------------------------------------------------------------------
init_ui() {
  if (( ! FORCE_TEXT )) && command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    USE_WT=1
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
    WT_MAX=$(( rows - 2 ))
    WT_W=$(( cols - 4 < 78 ? cols - 4 : 78 ))
    WT_LIST=$(( WT_MAX - 12 > 3 ? WT_MAX - 12 : 3 ))
    if (( WT_LIST > 10 )); then WT_LIST=10; fi
  fi
  return 0
}

# Size a dialog to fit its text: sets WT_H, and WT_SCROLL only if it can't fit.
wt_fit() { # text extra_rows
  local line n=0 w=$(( WT_W - 4 ))
  while IFS= read -r line; do n=$(( n + ${#line} / w + 1 )); done < <(printf '%b\n' "$1")
  WT_H=$(( n + $2 )); WT_SCROLL=()
  (( WT_H < 8 )) && WT_H=8
  if (( WT_H > WT_MAX )); then WT_H=$WT_MAX; WT_SCROLL=(--scrolltext); fi
}

need_tty() { [[ -r /dev/tty ]] || die "No terminal available. Use --config FILE for non-interactive runs."; }

ui_msg() { # title text
  if (( USE_WT )); then
    wt_fit "$2" 7
    whiptail --title "$1" --backtitle "$BACKTITLE" "${WT_SCROLL[@]}" --msgbox "$2" "$WT_H" "$WT_W"
  else
    need_tty
    printf '\n%s== %s ==%s\n%b\n' "$C_B" "$1" "$C_0" "$2" >/dev/tty
    read -r -p "Press Enter to continue... " _ </dev/tty 2>/dev/tty || true
  fi
}

ui_yesno() { # title text [default yes|no] [yes-label] [no-label]
  local def=${3:-yes}
  if (( USE_WT )); then
    local -a o=()
    [[ $def == no ]] && o+=(--defaultno)
    [[ -n ${4:-} ]] && o+=(--yes-button "$4")
    [[ -n ${5:-} ]] && o+=(--no-button "$5")
    wt_fit "$2" 7
    whiptail --title "$1" --backtitle "$BACKTITLE" "${o[@]}" "${WT_SCROLL[@]}" --yesno "$2" "$WT_H" "$WT_W"
  else
    need_tty
    local a hint="[Y/n]"; [[ $def == no ]] && hint="[y/N]"
    printf '\n%s== %s ==%s\n%b\n' "$C_B" "$1" "$C_0" "$2" >/dev/tty
    while true; do
      read -r -p "${4:-Yes}/${5:-No} $hint: " a </dev/tty 2>/dev/tty || return 1
      a=${a,,}; [[ -z $a ]] && a=${def:0:1}
      case $a in y|yes) return 0 ;; n|no) return 1 ;; esac
    done
  fi
}

ui_input() { # title text default
  if (( USE_WT )); then
    wt_fit "$2" 8
    whiptail --title "$1" --backtitle "$BACKTITLE" --inputbox "$2" "$WT_H" "$WT_W" "${3:-}" 3>&1 1>&2 2>&3
  else
    need_tty
    local a
    printf '\n%s== %s ==%s\n%b\n' "$C_B" "$1" "$C_0" "$2" >/dev/tty
    read -r -p "> [${3:-}] (q = cancel): " a </dev/tty 2>/dev/tty || return 1
    [[ $a == q ]] && return 1
    printf '%s' "${a:-${3:-}}"
  fi
}

ui_password() { # title text
  if (( USE_WT )); then
    wt_fit "$2" 8
    whiptail --title "$1" --backtitle "$BACKTITLE" --passwordbox "$2" "$WT_H" "$WT_W" 3>&1 1>&2 2>&3
  else
    need_tty
    local a
    printf '\n%s== %s ==%s\n%b\n' "$C_B" "$1" "$C_0" "$2" >/dev/tty
    read -r -s -p "> " a </dev/tty 2>/dev/tty || return 1
    printf '\n' >/dev/tty
    printf '%s' "$a"
  fi
}

ui_menu() { # title text default tag desc [tag desc]...
  local title=$1 text=$2 def=$3; shift 3
  if (( USE_WT )); then
    local -a o=(); [[ -n $def ]] && o+=(--default-item "$def")
    local n=$(( $# / 2 )); (( n > WT_LIST )) && n=$WT_LIST
    wt_fit "$text" $(( n + 7 ))
    whiptail --title "$title" --backtitle "$BACKTITLE" "${o[@]}" --menu "$text" "$WT_H" "$WT_W" "$n" "$@" 3>&1 1>&2 2>&3
  else
    need_tty
    local -a tags=() descs=(); local i a mark
    while (( $# )); do tags+=("$1"); descs+=("$2"); shift 2; done
    {
      printf '\n%s== %s ==%s\n%b\n\n' "$C_B" "$title" "$C_0" "$text"
      for i in "${!tags[@]}"; do
        mark=" "; [[ ${tags[i]} == "$def" ]] && mark="*"
        printf ' %s%2d) %-16s %s\n' "$mark" "$((i + 1))" "${tags[i]}" "${descs[i]}"
      done
    } >/dev/tty
    while true; do
      read -r -p "Choose a number (Enter = *, q = back): " a </dev/tty 2>/dev/tty || return 1
      [[ $a == q ]] && return 1
      if [[ -z $a && -n $def ]]; then printf '%s' "$def"; return 0; fi
      if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#tags[@]} )); then printf '%s' "${tags[a-1]}"; return 0; fi
    done
  fi
}

ui_checklist() { # title text tag desc ON|OFF ...   -> selected tags, one per line
  local title=$1 text=$2; shift 2
  if (( USE_WT )); then
    local n=$(( $# / 3 )); (( n > WT_LIST )) && n=$WT_LIST
    wt_fit "$text" $(( n + 7 ))
    whiptail --title "$title" --backtitle "$BACKTITLE" --separate-output --checklist "$text" "$WT_H" "$WT_W" "$n" "$@" 3>&1 1>&2 2>&3
  else
    need_tty
    local -a tags=() descs=() states=(); local i a sel
    while (( $# )); do tags+=("$1"); descs+=("$2"); states+=("$3"); shift 3; done
    {
      printf '\n%s== %s ==%s\n%b\n\n' "$C_B" "$title" "$C_0" "$text"
      for i in "${!tags[@]}"; do
        mark="[ ]"; [[ ${states[i]} == ON ]] && mark="[x]"
        printf ' %s %2d) %-12s %s\n' "$mark" "$((i + 1))" "${tags[i]}" "${descs[i]}"
      done
    } >/dev/tty
    local bad
    while true; do
      read -r -p "Numbers to select, space-separated (Enter = keep [x], 0 = none, q = back): " a </dev/tty 2>/dev/tty || return 1
      [[ $a == q ]] && return 1
      [[ $a == 0 ]] && return 0
      if [[ -z $a ]]; then
        for i in "${!tags[@]}"; do [[ ${states[i]} == ON ]] && printf '%s\n' "${tags[i]}"; done
        return 0
      fi
      bad=0
      for sel in $a; do
        [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#tags[@]} )) || bad=1
      done
      if (( bad )); then printf 'Please enter numbers between 1 and %d.\n' "${#tags[@]}" >/dev/tty; continue; fi
      for sel in $a; do printf '%s\n' "${tags[sel-1]}"; done
      return 0
    done
  fi
}

confirm_quit() {
  if ui_yesno "Quit setup?" "Quit the wizard now?\n\nNo changes have been made to your system." no "Quit" "Go back"; then
    clear 2>/dev/null || true
    say "Setup cancelled. No changes were made."
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# Validators
# ----------------------------------------------------------------------------
valid_mount_point() {
  local p=$1
  [[ $p =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ $p != *..* && $p != *//* ]] || return 1
  case $p in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/tmp/*|/usr/*|/var/*) return 1 ;;
  esac
  return 0
}
valid_share()    { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] && ! [[ ${1,,} =~ ^(global|homes|printers)$ ]]; }
valid_user()     { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
valid_label()    { [[ $1 =~ ^[A-Za-z0-9_-]{1,16}$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_folder()   { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ && $1 != . && $1 != .. ]]; }
is_linux_fs()    { [[ $1 =~ ^(ext2|ext3|ext4|xfs|btrfs|f2fs)$ ]]; }

# ----------------------------------------------------------------------------
# Drive discovery
# ----------------------------------------------------------------------------
# Parse one line of `lsblk -P` (KEY="value" pairs) into the R array.
parse_pairs() {
  R=()
  local s=$1 k v
  while [[ $s =~ ^[[:space:]]*([A-Z0-9:_-]+)=\"([^\"]*)\"(.*)$ ]]; do
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; s=${BASH_REMATCH[3]}
    printf -v v '%b' "$v"           # decode lsblk's \xNN escapes
    R[$k]=$v
  done
}

# Find the disk(s) that hold /, /boot/firmware and /boot. These are never offered.
find_system_disks() {
  PROTECTED_DISKS=()
  local mp src mm d
  for mp in / /boot/firmware /boot; do
    src=$(findmnt -n -o SOURCE --mountpoint "$mp" 2>/dev/null) || continue
    src=${src%%\[*}                               # strip btrfs subvolume suffix
    if [[ ! -b $src ]]; then                      # e.g. /dev/root
      mm=$(findmnt -n -o MAJ:MIN --mountpoint "$mp" 2>/dev/null || true)
      src=$(lsblk -nrpo NAME,MAJ:MIN 2>/dev/null | awk -v m="$mm" '$2==m {print $1; exit}')
    fi
    [[ -n $src && -b $src ]] || continue
    while read -r d; do
      [[ -n $d ]] && ! in_list "$d" "${PROTECTED_DISKS[@]}" && PROTECTED_DISKS+=("$d")
    done < <(lsblk -nplso NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk" {print $1}')
  done
  (( ${#PROTECTED_DISKS[@]} )) || die "Could not identify the system disk, so it is not safe to continue."
  log "System disk(s), hidden from selection: ${PROTECTED_DISKS[*]}"
}

collect_disks() {
  CAND_DISKS=() CAND_DESCS=()
  local line name bytes model tran
  while IFS= read -r line; do
    parse_pairs "$line"
    [[ ${R[TYPE]:-} == disk ]] || continue
    name=${R[NAME]:-}
    case $name in /dev/loop*|/dev/zram*|/dev/ram*|/dev/sr*|"") continue ;; esac
    in_list "$name" "${PROTECTED_DISKS[@]}" && continue
    bytes=$(lsblk -bdno SIZE "$name" 2>/dev/null | tr -d '[:space:]')
    [[ ${bytes:-0} =~ ^[0-9]+$ ]] && (( bytes > 0 )) || continue
    model=$(trim "${R[MODEL]:-}"); tran=${R[TRAN]:-}
    CAND_DISKS+=("$name")
    CAND_DESCS+=("${R[SIZE]:-?}  ${model:-Unknown drive}${tran:+  (${tran^^})}")
  done < <(lsblk -dnpP -o NAME,TYPE,SIZE,TRAN,MODEL 2>/dev/null)
}

# Wait for the kernel/udev to finish processing device changes.
settle() { if command -v udevadm >/dev/null 2>&1; then udevadm settle 2>/dev/null || sleep 1; else sleep 1; fi; }

disk_of() { lsblk -nplso NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk" {print $1; exit}'; }

# Fill PART_* from a partition (or whole-disk filesystem) device.
part_info() {
  local line
  line=$(lsblk -ndpP -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID "$1" 2>/dev/null | head -n1)
  parse_pairs "$line"
  PART=$1
  PART_SIZE=${R[SIZE]:-?}
  PART_FS=${R[FSTYPE]:-}
  PART_LABEL=${R[LABEL]:-}
  PART_MOUNT=${R[MOUNTPOINT]:-}
  PART_UUID=${R[UUID]:-}
  [[ -z $PART_FS ]] && PART_FS=$(blkid -o value -s TYPE "$1" 2>/dev/null || true)
  [[ -z $PART_UUID ]] && PART_UUID=$(blkid -o value -s UUID "$1" 2>/dev/null || true)
  return 0
}

# Predict the first partition's name: sda -> sda1, nvme0n1 -> nvme0n1p1
first_part_name() { if [[ $1 =~ [0-9]$ ]]; then printf '%sp1' "$1"; else printf '%s1' "$1"; fi; }

disk_desc_of() {
  local i
  for i in "${!CAND_DISKS[@]}"; do [[ ${CAND_DISKS[i]} == "$1" ]] && { printf '%s' "${CAND_DESCS[i]}"; return; }; done
  lsblk -dno SIZE,MODEL "$1" 2>/dev/null | head -n1 || true
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
preflight() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  local os_id os_like os_name
  os_id=$(. /etc/os-release; printf '%s' "${ID:-}")
  os_like=$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")
  os_name=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")
  [[ $os_id == debian || $os_id == raspbian || $os_like == *debian* ]] \
    || die "This script supports Raspberry Pi OS / Debian only (found: $os_name)."
  PI_MODEL=$( { tr -d '\0' </proc/device-tree/model; } 2>/dev/null || echo "unknown device")
  log "Device: $PI_MODEL | OS: $os_name"
  local c
  for c in lsblk findmnt blkid wipefs mountpoint runuser awk; do
    command -v "$c" >/dev/null 2>&1 || die "Required command missing: $c"
  done
  find_system_disks
  if ! getent hosts deb.debian.org >/dev/null 2>&1 && ! getent hosts archive.raspberrypi.com >/dev/null 2>&1; then
    warn "Package servers can't be resolved. Package installation will probably fail without internet."
  fi
}

# ----------------------------------------------------------------------------
# Wizard questions
# ----------------------------------------------------------------------------
q_welcome() {
  ui_msg "Welcome" "This wizard turns your Raspberry Pi into a NAS:\n\n  - Finds your external drive (the system disk is hidden)\n  - Formats it as ext4, or keeps the data already on it\n  - Mounts it permanently at a folder you choose\n  - Installs Samba with Apple / iOS Files compatibility\n  - Creates the share, user and folders, then tests it all\n\nNothing changes until you review and approve a summary.\n\nDevice: $PI_MODEL\nSystem disk (hidden): ${PROTECTED_DISKS[*]}$( (( DRY_RUN )) && printf '\n\nDRY RUN: commands will be shown, not executed.')"
}

q_drive() {
  local def_disk="" def_part="" choice i
  if [[ -n $PART_UUID ]]; then
    def_part=$(blkid -U "$PART_UUID" 2>/dev/null || true)
    [[ -n $def_part ]] && def_disk=$(disk_of "$def_part")
  fi
  while true; do
    collect_disks
    if (( ${#CAND_DISKS[@]} == 0 )); then
      if ui_yesno "No drive found" "No external drive was detected.\n\nThe system disk (${PROTECTED_DISKS[*]}) is hidden for safety.\n\nPlug in the USB HDD, wait about 10 seconds, then choose Rescan." yes "Rescan" "Quit"; then
        sleep 2; continue
      fi
      say "Setup cancelled. No changes were made."; exit 0
    fi
    local -a items=()
    for i in "${!CAND_DISKS[@]}"; do items+=("${CAND_DISKS[i]}" "${CAND_DESCS[i]}"); done
    items+=("RESCAN" "Rescan for drives")
    in_list "$def_disk" "${CAND_DISKS[@]}" || def_disk=${CAND_DISKS[0]}
    until choice=$(ui_menu "Select the data drive" "Choose the drive to use for NAS storage.\nThe system disk is not listed." "$def_disk" "${items[@]}"); do
      confirm_quit
    done
    [[ $choice == RESCAN ]] && continue
    DISK=$choice; DISK_DESC=$(disk_desc_of "$DISK"); def_disk=$DISK
    q_partition "$def_part" && return 0
  done
}

# Returns 1 to go back to the disk list.
q_partition() {
  local def_part=$1 line choice act
  while true; do
    local -a items=() parts=()
    while IFS= read -r line; do
      parse_pairs "$line"
      [[ ${R[TYPE]:-} == part ]] || continue
      parts+=("${R[NAME]}")
      [[ -n ${R[FSTYPE]:-} ]] || R[FSTYPE]=$(blkid -o value -s TYPE "${R[NAME]}" 2>/dev/null || true)
      items+=("${R[NAME]}" "$(printf '%-8s %-6s %s%s' "${R[SIZE]:-?}" "${R[FSTYPE]:-none}" "${R[LABEL]:+\"${R[LABEL]}\" }" "${R[MOUNTPOINT]:+[mounted ${R[MOUNTPOINT]}]}")")
    done < <(lsblk -npP -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null)
    if (( ${#parts[@]} == 0 )); then               # filesystem directly on the disk?
      part_info "$DISK"
      if [[ -n $PART_FS ]]; then
        parts+=("$DISK"); items+=("$DISK" "$PART_SIZE  $PART_FS (whole-disk filesystem)")
      fi
    fi
    items+=("ERASE" "Erase the WHOLE disk and create one ext4 partition")
    in_list "$def_part" "${parts[@]}" || def_part=${parts[0]:-ERASE}

    choice=$(ui_menu "Drive: $DISK" "$DISK_DESC\n\nPick a partition to use, or erase the whole disk." "$def_part" "${items[@]}") || return 1

    if [[ $choice == ERASE ]]; then
      if ui_yesno "Erase whole disk?" "ALL data on $DISK ($DISK_DESC) will be destroyed:\nevery partition and every file.\n\nA new GPT partition table with one ext4 partition will be created.\n\nYou will be asked to type ERASE before anything happens." no "Erase it" "Back"; then
        ACTION="wipe_disk"; PART=""; PART_FS="ext4"; PART_UUID=""; PART_MOUNT=""; PART_SIZE=""; PART_LABEL=""
        return 0
      fi
      continue
    fi

    part_info "$choice"
    if is_linux_fs "$PART_FS"; then
      act=$(ui_menu "Partition $PART" "$PART is $PART_SIZE, formatted as $PART_FS${PART_LABEL:+ (label \"$PART_LABEL\")}.\n\nWhat should happen to it?" "KEEP" \
            "KEEP"   "Keep the existing data and mount it" \
            "FORMAT" "Erase this partition and format it as ext4") || continue
    elif [[ -z $PART_FS ]]; then
      act=$(ui_menu "Partition $PART" "$PART ($PART_SIZE) has no filesystem." "FORMAT" \
            "FORMAT" "Format it as ext4" "BACK" "Choose something else") || continue
    else
      act=$(ui_menu "Partition $PART" "$PART ($PART_SIZE) is formatted as $PART_FS.\n\n$PART_FS doesn't support Linux extended attributes reliably. Samba's Apple settings need them, and without them the iOS Files app fails with 'error -61' when writing.\n\nCopy any files you need off this drive first. Then format it as ext4." "BACK" \
            "BACK"   "Go back (I need to copy my data off first)" \
            "FORMAT" "Erase this partition and format it as ext4") || continue
    fi
    case $act in
      KEEP)   ACTION="keep";        return 0 ;;
      FORMAT) ACTION="format_part"; return 0 ;;
      *)      def_part=$PART; continue ;;
    esac
  done
}

# Prints a reason and returns 1 if the mount point can't be used.
mount_point_problem() {
  local mp=$1 src uuid
  valid_mount_point "$mp" || { printf 'Use an absolute path such as /srv/nas or /mnt/nas, with only letters, numbers, ".", "_", "-" and "/". System folders like /etc, /usr or /home itself are not allowed.'; return 1; }
  [[ -e $mp && ! -d $mp ]] && { printf '%s exists and is not a folder.' "$mp"; return 1; }
  if mountpoint -q "$mp" 2>/dev/null; then
    uuid=$(findmnt -n -o UUID --mountpoint "$mp" 2>/dev/null || true)
    src=$(findmnt -n -o SOURCE --mountpoint "$mp" 2>/dev/null || true)
    if [[ $ACTION == keep && -n $PART_UUID && $uuid == "$PART_UUID" ]]; then return 0; fi
    printf '%s is already in use: %s is mounted there.' "$mp" "${src:-another device}"; return 1
  fi
  return 0
}

q_mount_point() {
  local mp why
  while true; do
    until mp=$(ui_input "Mount point" "Folder where the drive will be mounted:" "$MOUNT_POINT"); do confirm_quit; done
    mp=$(trim "$mp"); [[ $mp != / ]] && mp=${mp%/}
    if ! why=$(mount_point_problem "$mp"); then ui_msg "Can't use that folder" "$why"; continue; fi
    if [[ -d $mp ]] && ! mountpoint -q "$mp" && [[ -n $(ls -A "$mp" 2>/dev/null) ]]; then
      ui_yesno "Folder not empty" "$mp already contains files.\n\nThey won't be deleted, but they'll be hidden while the drive is mounted over them.\n\nUse this folder anyway?" no || continue
    fi
    MOUNT_POINT=$mp; return 0
  done
}

q_label() {
  [[ $ACTION == keep ]] && return 0
  local l
  while true; do
    until l=$(ui_input "Drive label" "Name (label) for the new ext4 filesystem.\nUp to 16 letters, numbers, '_' or '-':" "$FS_LABEL"); do confirm_quit; done
    l=$(trim "$l")
    valid_label "$l" && { FS_LABEL=$l; return 0; }
    ui_msg "Invalid label" "Use 1-16 characters: letters, numbers, '_' or '-'."
  done
}

q_share() {
  local s
  while true; do
    until s=$(ui_input "Share name" "Name of the Samba share.\nClients will connect to smb://<pi>/<name>:" "$SHARE_NAME"); do confirm_quit; done
    s=$(trim "$s")
    valid_share "$s" && { SHARE_NAME=$s; return 0; }
    ui_msg "Invalid share name" "Use 1-32 characters: letters, numbers, '_' or '-'.\n'global', 'homes' and 'printers' are reserved."
  done
}

q_user() {
  local u def=${SMB_USER:-}
  [[ -z $def && -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]] && def=$SUDO_USER
  [[ -z $def ]] && def="nasadmin"
  while true; do
    until u=$(ui_input "Samba user" "Username for logging in to the share.\nIt can be your existing Linux user or a new account for file sharing only:" "$def"); do confirm_quit; done
    u=$(trim "$u"); u=${u,,}
    if ! valid_user "$u"; then ui_msg "Invalid username" "Use lowercase letters, numbers, '_' or '-', starting with a letter. 'root' is not allowed."; continue; fi
    if id "$u" >/dev/null 2>&1; then SMB_USER=$u; CREATE_USER="no"; return 0; fi
    if ui_yesno "Create user?" "There is no Linux user called '$u'.\n\nCreate it as a file-sharing-only account? It won't be able to log in over SSH." yes "Create" "Back"; then
      SMB_USER=$u; CREATE_USER="yes"; return 0
    fi
  done
}

q_password() {
  local p1 p2
  if [[ $CREATE_USER == no ]] && command -v pdbedit >/dev/null 2>&1 && pdbedit -u "$SMB_USER" >/dev/null 2>&1; then
    if ui_yesno "Samba password" "'$SMB_USER' already has a Samba password.\n\nKeep it?" yes "Keep" "Change"; then
      SET_PASSWORD="no"; return 0
    fi
  fi
  while true; do
    until p1=$(ui_password "Samba password" "Password for '$SMB_USER' on the share (8+ characters).\nIt can be different from the Linux login password:"); do confirm_quit; done
    if (( ${#p1} < 8 )); then ui_msg "Too short" "Use at least 8 characters."; continue; fi
    until p2=$(ui_password "Samba password" "Type the password again:"); do confirm_quit; done
    [[ $p1 == "$p2" ]] && { SMB_PASSWORD=$p1; SET_PASSWORD="yes"; return 0; }
    ui_msg "Mismatch" "The passwords didn't match. Try again."
  done
}

q_folders() {
  local -a base=(Shared Backups Media Documents Photos) items=() current=() picked=()
  local f extra sel bad
  read -r -a current <<<"$FOLDERS"
  for f in "${current[@]}"; do in_list "$f" "${base[@]}" || base+=("$f"); done
  for f in "${base[@]}"; do
    items+=("$f" "folder in the share" "$(in_list "$f" "${current[@]}" && echo ON || echo OFF)")
  done
  until sel=$(ui_checklist "Folders" "Folders to create on the drive (Space toggles, Enter confirms):" "${items[@]}"); do confirm_quit; done
  mapfile -t picked <<<"$sel"
  while true; do
    until extra=$(ui_input "More folders" "Any extra folder names, separated by spaces (leave empty for none):" ""); do confirm_quit; done
    bad=""
    for f in $extra; do valid_folder "$f" || bad+="$f "; done
    [[ -z $bad ]] && break
    ui_msg "Invalid folder name" "Not allowed: $bad\n\nUse letters, numbers, '.', '_' or '-' (no spaces inside a name)."
  done
  local -a all=()
  for f in "${picked[@]}" $extra; do [[ -n $f ]] && ! in_list "$f" "${all[@]}" && all+=("$f"); done
  FOLDERS="${all[*]}"
}

q_options() {
  local sel h cur
  until sel=$(ui_checklist "Options" "Choose options (Space toggles, Enter confirms):" \
        apple   "Apple / iOS Files compatibility (recommended)" "$([[ $APPLE_COMPAT == yes ]] && echo ON || echo OFF)" \
        upgrade "Upgrade system packages first (apt full-upgrade)" "$([[ $UPGRADE == yes ]] && echo ON || echo OFF)"); do
    confirm_quit
  done
  [[ $sel == *apple* ]] && APPLE_COMPAT="yes" || APPLE_COMPAT="no"
  [[ $sel == *upgrade* ]] && UPGRADE="yes" || UPGRADE="no"

  cur=$(hostname)
  while true; do
    until h=$(ui_input "Hostname" "Network name of this Pi (reach it as <name>.local).\nKeep the current name or type a new one:" "${NEW_HOSTNAME:-$cur}"); do confirm_quit; done
    h=$(trim "$h"); h=${h,,}
    valid_hostname "$h" && { NEW_HOSTNAME=$h; return 0; }
    ui_msg "Invalid hostname" "Use lowercase letters, numbers and '-' (not at the start or end), up to 63 characters."
  done
}

q_fix_owner() {
  [[ $ACTION == keep ]] || { FIX_OWNERSHIP="no"; return 0; }
  if ui_yesno "Existing files" "The drive keeps its current files.\n\nGive '$SMB_USER' ownership of ALL existing files and folders on it?\nChoose Yes if files were created on another computer and you can't write to them over the share." no; then
    FIX_OWNERSHIP="yes"
  else
    FIX_OWNERSHIP="no"
  fi
}

review_text() {
  local t drive_action host_line
  case $ACTION in
    wipe_disk)   drive_action="ERASE ENTIRE DISK $DISK, create one ext4 partition (label $FS_LABEL)" ;;
    format_part) drive_action="ERASE partition $PART ($PART_SIZE) and format it as ext4 (label $FS_LABEL)" ;;
    keep)        drive_action="Keep existing data on $PART ($PART_SIZE, $PART_FS)"
                 [[ -n $PART_MOUNT && $PART_MOUNT != "$MOUNT_POINT" ]] && drive_action+="; unmount it from $PART_MOUNT first" ;;
  esac
  if [[ -n $NEW_HOSTNAME && $NEW_HOSTNAME != "$(hostname)" ]]; then host_line="$(hostname) -> $NEW_HOSTNAME"; else host_line="$(hostname) (unchanged)"; fi
  t="Drive:        $DISK  ($DISK_DESC)\n"
  t+="Action:       $drive_action\n"
  t+="Mount point:  $MOUNT_POINT  (mounted automatically at boot)\n"
  t+="Share:        $SHARE_NAME\n"
  local new_user=""; [[ $CREATE_USER == yes ]] && new_user=" (new file-sharing-only account)"
  t+="Samba user:   $SMB_USER$new_user\n"
  t+="Password:     $([[ $SET_PASSWORD == yes ]] && echo 'will be set' || echo 'keep existing')\n"
  t+="Folders:      ${FOLDERS:-none}\n"
  [[ $ACTION == keep ]] && t+="Fix owners:   $FIX_OWNERSHIP\n"
  t+="Apple / iOS:  $APPLE_COMPAT\n"
  t+="Upgrade OS:   $UPGRADE\n"
  t+="Hostname:     $host_line\n"
  printf '%s' "$t"
}

confirm_apply() {
  local t; t=$(review_text)
  if (( USE_WT )) || [[ -r /dev/tty ]]; then
    ui_yesno "Review and apply" "$t\nApply these settings?$( (( DRY_RUN )) && printf ' (dry run: nothing will change)')" yes "Apply" "Cancel" || { say "Cancelled. No changes were made."; exit 0; }
  fi
}

confirm_erase() {
  [[ $ACTION == keep ]] && return 0
  (( DRY_RUN )) && return 0
  local target=${PART:-$DISK} a
  if [[ -n $CONFIG_FILE ]]; then
    [[ $CONFIRM_ERASE == "$target" ]] || die "Refusing to erase $target: set CONFIRM_ERASE=$target in the config file."
    return 0
  fi
  until a=$(ui_input "Final confirmation" "Everything on $target ($DISK_DESC) will be permanently erased.\n\nType ERASE (capital letters) to continue:" ""); do confirm_quit; done
  [[ $a == ERASE ]] || { say "Confirmation not given. No changes were made."; exit 0; }
}

# ----------------------------------------------------------------------------
# Non-interactive (config file) mode
# ----------------------------------------------------------------------------
readonly KV_KEYS="DISK PART PART_UUID ACTION MOUNT_POINT FS_LABEL SHARE_NAME SMB_USER CREATE_USER FOLDERS APPLE_COMPAT UPGRADE NEW_HOSTNAME FIX_OWNERSHIP CONFIRM_ERASE SMB_PASSWORD_FILE"

load_kv_file() { # Parses KEY=value lines; only whitelisted keys; never executes the file.
  local f=$1 k v
  [[ -r $f ]] || die "Cannot read $f"
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "$line")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || continue
    k=$(trim "${line%%=*}"); v=$(trim "${line#*=}")
    v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    if in_list "$k" $KV_KEYS; then printf -v "$k" '%s' "$v"; else warn "Ignoring unknown key in $f: $k"; fi
  done <"$f"
}

prepare_noninteractive() {
  case $ACTION in keep|format_part|wipe_disk) ;; *) die "ACTION must be keep, format_part or wipe_disk." ;; esac
  if [[ $ACTION == wipe_disk ]]; then
    [[ -b $DISK ]] || die "DISK=$DISK is not a block device."
    [[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "DISK=$DISK is not a whole disk."
    PART=""; PART_FS="ext4"
  else
    [[ -z $PART && -n $PART_UUID ]] && PART=$(blkid -U "$PART_UUID" 2>/dev/null || true)
    [[ -b $PART ]] || die "PART (or PART_UUID) must point to an existing partition."
    part_info "$PART"
    DISK=$(disk_of "$PART")
    if [[ $ACTION == keep ]]; then
      is_linux_fs "$PART_FS" || die "$PART is '${PART_FS:-unformatted}'; ACTION=keep needs ext4/xfs/btrfs."
    fi
  fi
  in_list "$DISK" "${PROTECTED_DISKS[@]}" && die "$DISK is the system disk. Refusing."
  collect_disks; DISK_DESC=$(disk_desc_of "$DISK")
  local why
  MOUNT_POINT=${MOUNT_POINT%/}
  why=$(mount_point_problem "$MOUNT_POINT") || die "MOUNT_POINT: $why"
  valid_label "$FS_LABEL"   || die "FS_LABEL is invalid."
  valid_share "$SHARE_NAME" || die "SHARE_NAME is invalid."
  [[ -z $SMB_USER && -n ${SUDO_USER:-} && $SUDO_USER != root ]] && SMB_USER=$SUDO_USER
  valid_user "$SMB_USER"    || die "SMB_USER is invalid or empty."
  if ! id "$SMB_USER" >/dev/null 2>&1; then
    [[ $CREATE_USER == yes ]] || die "User $SMB_USER doesn't exist. Set CREATE_USER=yes to create it."
  else
    CREATE_USER="no"
  fi
  local f; for f in $FOLDERS; do valid_folder "$f" || die "Invalid folder name: $f"; done
  [[ -z $NEW_HOSTNAME ]] || valid_hostname "$NEW_HOSTNAME" || die "NEW_HOSTNAME is invalid."
  if [[ -n ${PINAS_SMB_PASSWORD:-} ]]; then
    SMB_PASSWORD=$PINAS_SMB_PASSWORD
  elif [[ -n $SMB_PASSWORD_FILE ]]; then
    [[ -r $SMB_PASSWORD_FILE ]] || die "Cannot read SMB_PASSWORD_FILE."
    IFS= read -r SMB_PASSWORD <"$SMB_PASSWORD_FILE" || true
  fi
  if [[ -n $SMB_PASSWORD ]]; then
    (( ${#SMB_PASSWORD} >= 8 )) || die "Samba password must be at least 8 characters."
    SET_PASSWORD="yes"
  elif command -v pdbedit >/dev/null 2>&1 && pdbedit -u "$SMB_USER" >/dev/null 2>&1; then
    SET_PASSWORD="no"
  else
    die "No Samba password given. Set PINAS_SMB_PASSWORD (use sudo -E) or SMB_PASSWORD_FILE."
  fi
}

# ----------------------------------------------------------------------------
# File editing helpers
# ----------------------------------------------------------------------------
# install_file DEST NEWFILE : back up DEST, then replace it (diff only in dry-run)
install_file() {
  local dest=$1 new=$2
  if (( DRY_RUN )); then
    say "  Planned changes to $dest:"
    diff -u "$( [[ -f $dest ]] && echo "$dest" || echo /dev/null)" "$new" --label "$dest (current)" --label "$dest (new)" | sed 's/^/    /' || true
    return 0
  fi
  if [[ -f $dest ]]; then
    LAST_BACKUP="$dest.$MARK-$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$dest" "$LAST_BACKUP"
    log "Backed up $dest -> $LAST_BACKUP"
  fi
  cat "$new" >"$dest"
}

restore_backup() { # DEST
  [[ -n $LAST_BACKUP && -f $LAST_BACKUP ]] || return 0
  cp -a "$LAST_BACKUP" "$1" && warn "Restored $1 from $LAST_BACKUP"
}

# New fstab: drop our old block, comment out lines that clash, append our block.
build_fstab() { # SRC OUT MOUNTPOINT UUID DEVICE FSTYPE
  local src=$1 out=$2 mp=$3 uuid=$4 dev=$5 fs=$6 pass=2
  [[ $fs == ext* ]] || pass=0
  awk -v mp="$mp" -v uuid="$uuid" -v dev="$dev" -v mark="$MARK" '
    $0 ~ "^# BEGIN " mark { skip = 1; next }
    $0 ~ "^# END " mark   { skip = 0; next }
    skip { next }
    /^[ \t]*#/ || NF < 2 { print; next }
    $2 == mp || (uuid != "" && ($1 == "UUID=" uuid || $1 == "UUID=\"" uuid "\"")) || (dev != "" && $1 == dev) {
      print "# " mark " disabled: " $0; next
    }
    { print }
  ' "$src" >"$out"
  {
    printf '# BEGIN %s (managed by %s; this block is replaced on re-run)\n' "$MARK" "$PROG"
    printf 'UUID=%s  %s  %s  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  %s\n' "$uuid" "$mp" "$fs" "$pass"
    printf '# END %s\n' "$MARK"
  } >>"$out"
}

# New smb.conf: insert our global block after [global], comment out clashing
# global keys and any existing section with the same share name, append share.
build_smbconf() { # SRC OUT GLOBALBLOCK SHAREBLOCK
  local src=$1 out=$2 g=$3 s=$4
  awk -v share="${SHARE_NAME,,}" -v gfile="$g" -v sfile="$s" -v apple="$APPLE_COMPAT" -v mark="$MARK" '
    function norm(k) { k = tolower(k); gsub(/[ \t]/, "", k); return k }
    # Blank lines are held back so re-runs never pile up empty lines at the end.
    function out(l) { if (l ~ /^[ \t]*$/) { nb++; return } while (nb > 0) { print ""; nb-- } print l; any = 1 }
    function dump(f,   l) { while ((getline l < f) > 0) out(l); close(f) }
    $0 ~ "^[ \t]*# BEGIN " mark { skip = 1; next }
    $0 ~ "^[ \t]*# END " mark   { skip = 0; next }
    skip { next }
    /^[ \t]*\[[^]]+\]/ {
      h = $0; sub(/^[ \t]*\[/, "", h); sub(/\].*$/, "", h); gsub(/^[ \t]+|[ \t]+$/, "", h); sec = tolower(h)
      if (sec == share) { out("# " mark " disabled: " $0); next }
      out($0)
      if (sec == "global" && !done) { dump(gfile); done = 1 }
      next
    }
    sec == share { if ($0 ~ /^[ \t]*$/) out($0); else out("# " mark " disabled: " $0); next }
    sec == "global" && /^[ \t]*[^#;[ \t][^=]*=/ {
      k = $0; sub(/=.*/, "", k); k = norm(k)
      if (k == "minprotocol" || k == "serverminprotocol" ||
          (apple == "yes" && (k == "vfsobjects" || k == "vfsobject" || k ~ /^fruit:/))) {
        out("# " mark " disabled: " $0); next
      }
    }
    { out($0) }
    END {
      if (!done) { out("[global]"); dump(gfile) }
      nb = 0; if (any) print ""
      dump(sfile)
    }
  ' "$src" >"$out"
}

write_samba_blocks() { # GLOBALOUT SHAREOUT
  local g=$1 s=$2 cur others="" m
  if [[ $APPLE_COMPAT == yes && -f /etc/samba/smb.conf ]] && command -v testparm >/dev/null 2>&1; then
    cur=$(testparm -s --parameter-name="vfs objects" /etc/samba/smb.conf 2>/dev/null || true)
    for m in $cur; do in_list "$m" catia fruit streams_xattr || others+=" $m"; done
  fi
  {
    printf '   # BEGIN %s global (managed by %s; replaced on re-run)\n' "$MARK" "$PROG"
    printf '   server min protocol = SMB2\n'
    if [[ $APPLE_COMPAT == yes ]]; then
      printf '   vfs objects = catia fruit streams_xattr%s\n' "$others"
      printf '   fruit:metadata = stream\n'
      printf '   fruit:model = MacSamba\n'
      printf '   fruit:posix_rename = yes\n'
      printf '   fruit:veto_appledouble = no\n'
      printf '   fruit:nfs_aces = no\n'
      printf '   fruit:wipe_intentionally_left_blank_rfork = yes\n'
      printf '   fruit:delete_empty_adfiles = yes\n'
    fi
    printf '   # END %s global\n' "$MARK"
  } >"$g"
  {
    printf '# BEGIN %s share (managed by %s; replaced on re-run)\n' "$MARK" "$PROG"
    printf '[%s]\n' "$SHARE_NAME"
    printf '   comment = Raspberry Pi NAS Storage\n'
    printf '   path = %s\n' "$MOUNT_POINT"
    printf '   browseable = yes\n'
    printf '   read only = no\n'
    printf '   guest ok = no\n'
    printf '   valid users = %s\n' "$SMB_USER"
    printf '   create mask = 0660\n'
    printf '   directory mask = 2770\n'
    printf '   hide files = /lost+found/\n'
    printf '# END %s share\n' "$MARK"
  } >"$s"
}

# ----------------------------------------------------------------------------
# Apply steps
# ----------------------------------------------------------------------------
apply_packages() {
  step "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  local -a apt=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  run "${apt[@]}" update
  if [[ $UPGRADE == yes ]]; then
    say "  Upgrading the system. This can take several minutes..."
    run "${apt[@]}" -y full-upgrade
  fi
  local -a pkgs=(samba samba-common-bin samba-vfs-modules smbclient attr parted e2fsprogs)
  [[ $PART_FS == xfs ]] && pkgs+=(xfsprogs)
  [[ $PART_FS == btrfs ]] && pkgs+=(btrfs-progs)
  run "${apt[@]}" -y install "${pkgs[@]}"
  ok "Packages installed"
}

apply_system() {
  step "Hostname and user account"
  local cur; cur=$(hostname)
  if [[ -n $NEW_HOSTNAME && $NEW_HOSTNAME != "$cur" ]]; then
    run hostnamectl set-hostname "$NEW_HOSTNAME"
    local new="$TMP/hosts"
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts >"$new"
    else
      { cat /etc/hosts; printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME"; } >"$new"
    fi
    install_file /etc/hosts "$new"
    ok "Hostname set to $NEW_HOSTNAME"
  else
    ok "Hostname unchanged ($cur)"
  fi
  if [[ $CREATE_USER == yes ]] && ! id "$SMB_USER" >/dev/null 2>&1; then
    run useradd -M -s /usr/sbin/nologin -c "NAS file-sharing account" "$SMB_USER"
    ok "Created file-sharing user $SMB_USER (no SSH login)"
  else
    ok "Using existing user $SMB_USER"
  fi
}

unmount_device() {
  local dev=$1 m
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    run umount "$m"
  done < <(lsblk -nrpo NAME,MOUNTPOINT "$dev" 2>/dev/null | awk 'NF >= 2 {print $1}')
}

apply_drive() {
  step "Preparing the drive"
  case $ACTION in
    wipe_disk)
      say "  Erasing $DISK and creating a new partition..."
      unmount_device "$DISK"
      local p
      while read -r p; do if [[ -n $p ]]; then run wipefs -a "$p"; fi; done \
        < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part" {print $1}')
      run wipefs -a "$DISK"
      run parted -s -a optimal "$DISK" mklabel gpt mkpart nasdata ext4 0% 100%
      run partprobe "$DISK" || true
      settle
      if (( DRY_RUN )); then
        PART=$(first_part_name "$DISK")
      else
        local i
        for i in {1..20}; do
          PART=$(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part" {print $1; exit}')
          [[ -n $PART && -b $PART ]] && break
          sleep 0.5
        done
        [[ -n $PART && -b $PART ]] || die "The new partition did not appear on $DISK."
      fi
      run wipefs -a "$PART"
      say "  Formatting $PART as ext4..."
      run mkfs.ext4 -F -L "$FS_LABEL" "$PART"
      PART_FS="ext4"
      ;;
    format_part)
      unmount_device "$PART"
      run wipefs -a "$PART"
      say "  Formatting $PART as ext4..."
      run mkfs.ext4 -F -L "$FS_LABEL" "$PART"
      PART_FS="ext4"
      ;;
    keep)
      if [[ -n $PART_MOUNT && $PART_MOUNT != "$MOUNT_POINT" ]]; then
        run umount "$PART"
      fi
      ;;
  esac
  if (( DRY_RUN )) && [[ $ACTION != keep ]]; then
    PART_UUID="<new-uuid>"
  else
    settle
    PART_UUID=$(blkid -s UUID -o value "$PART" 2>/dev/null || true)
    [[ -n $PART_UUID ]] || die "Could not read the filesystem UUID of $PART."
  fi
  ok "Drive ready: $PART ($PART_FS, UUID $PART_UUID)"
}

apply_mount() {
  step "Mounting the drive permanently"
  if [[ ! -d $MOUNT_POINT ]]; then run mkdir -p "$MOUNT_POINT"; fi
  # Make the empty mount-point folder immutable: if the drive is ever missing,
  # nothing (not even Samba) can write files onto the microSD by mistake.
  if (( ! DRY_RUN )) && ! mountpoint -q "$MOUNT_POINT" && [[ -z $(ls -A "$MOUNT_POINT" 2>/dev/null) ]]; then
    if chattr +i "$MOUNT_POINT" 2>/dev/null; then
      ok "Protected empty $MOUNT_POINT against writes while the drive is unmounted"
    else
      warn "Couldn't protect $MOUNT_POINT with chattr (optional; continuing)"
    fi
  fi

  build_fstab /etc/fstab "$TMP/fstab" "$MOUNT_POINT" "$PART_UUID" "$PART" "$PART_FS"
  install_file /etc/fstab "$TMP/fstab"
  if (( DRY_RUN )); then run systemctl daemon-reload; run mount "$MOUNT_POINT"; return 0; fi

  if ! findmnt --verify --tab-file /etc/fstab >>"$LOG_FILE" 2>&1; then
    warn "findmnt --verify reported issues in /etc/fstab (details in the log). Testing the mount anyway."
  fi
  run systemctl daemon-reload
  if mountpoint -q "$MOUNT_POINT" && [[ $(findmnt -n -o UUID --mountpoint "$MOUNT_POINT") == "$PART_UUID" ]]; then
    ok "Already mounted at $MOUNT_POINT"
  elif ! run mount "$MOUNT_POINT"; then
    restore_backup /etc/fstab; systemctl daemon-reload || true
    die "Mounting failed, so /etc/fstab was restored. See $LOG_FILE."
  fi
  [[ $(findmnt -n -o UUID --mountpoint "$MOUNT_POINT") == "$PART_UUID" ]] \
    || { restore_backup /etc/fstab; die "$MOUNT_POINT is not backed by $PART after mounting."; }
  ok "Mounted $PART at $MOUNT_POINT ($(df -h --output=avail "$MOUNT_POINT" | tail -n1 | tr -d ' ') free)"
}

apply_folders() {
  step "Folders and permissions"
  (( DRY_RUN )) || mountpoint -q "$MOUNT_POINT" || die "$MOUNT_POINT is not mounted. Refusing to write to the microSD card."
  local grp f
  grp=$(id -gn "$SMB_USER" 2>/dev/null || echo "$SMB_USER")
  run chown "$SMB_USER:$grp" "$MOUNT_POINT"
  run chmod 2770 "$MOUNT_POINT"
  for f in $FOLDERS; do
    if [[ -d $MOUNT_POINT/$f ]]; then
      run chown "$SMB_USER:$grp" "$MOUNT_POINT/$f"
      run chmod 2770 "$MOUNT_POINT/$f"
    else
      run install -d -o "$SMB_USER" -g "$grp" -m 2770 "$MOUNT_POINT/$f"
    fi
  done
  if [[ $FIX_OWNERSHIP == yes ]]; then
    say "  Changing ownership of existing files (can take a while on big drives)..."
    run chown -R "$SMB_USER:$grp" "$MOUNT_POINT"
    run chmod -R u+rwX,g+rwX "$MOUNT_POINT"
    run find "$MOUNT_POINT" -type d -exec chmod g+s {} +
  fi
  ok "Owner $SMB_USER:$grp, mode 2770; folders: ${FOLDERS:-none}"
}

apply_samba_user() {
  step "Samba user"
  if [[ $SET_PASSWORD == yes ]]; then
    log "+ smbpasswd -s -a $SMB_USER (password via stdin)"
    if (( DRY_RUN )); then
      printf '  %s[dry-run]%s smbpasswd -s -a %s   (password from the wizard)\n' "$C_Y" "$C_0" "$SMB_USER"
    else
      printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s -a "$SMB_USER" >>"$LOG_FILE" 2>&1 \
        || die "Setting the Samba password failed."
    fi
  fi
  run smbpasswd -e "$SMB_USER"
  ok "Samba login enabled for $SMB_USER"
}

apply_samba_conf() {
  step "Configuring Samba"
  local conf=/etc/samba/smb.conf src out=$TMP/smb.conf.new out_msgs p
  src=$conf; [[ -f $src ]] || { (( DRY_RUN )) || die "$conf not found. Did the samba install fail?"; src=/dev/null; }
  write_samba_blocks "$TMP/global.blk" "$TMP/share.blk"
  build_smbconf "$src" "$out" "$TMP/global.blk" "$TMP/share.blk"

  if command -v testparm >/dev/null 2>&1; then
    out_msgs=$(testparm -s "$out" 2>&1 >/dev/null || true)
    log "testparm: $out_msgs"
    if ! grep -q "Loaded services file OK" <<<"$out_msgs"; then
      printf '%s\n' "$out_msgs" >&2
      die "The new Samba configuration failed validation. $conf was not changed."
    fi
    p=$(testparm -s --section-name="$SHARE_NAME" --parameter-name=path "$out" 2>/dev/null || true)
    [[ $p == "$MOUNT_POINT" ]] || die "Validation: share path is '$p', expected '$MOUNT_POINT'. $conf was not changed."
    ok "New configuration passed testparm"
  fi

  install_file "$conf" "$out"
  run systemctl enable smbd
  run systemctl restart smbd
  if (( ! DRY_RUN )) && ! systemctl is-active --quiet smbd; then
    restore_backup "$conf"; systemctl restart smbd || true
    die "smbd didn't start with the new configuration. The previous smb.conf was restored."
  fi
  ok "Samba is running with share [$SHARE_NAME] -> $MOUNT_POINT"
}

save_state() {
  (( DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR"
  {
    printf '# Saved by %s v%s on %s. Used as defaults when re-running.\n' "$PROG" "$SCRIPT_VERSION" "$(date '+%F %T')"
    printf 'PART_UUID=%s\nACTION=keep\nMOUNT_POINT=%s\nFS_LABEL=%s\nSHARE_NAME=%s\nSMB_USER=%s\n' \
      "$PART_UUID" "$MOUNT_POINT" "$FS_LABEL" "$SHARE_NAME" "$SMB_USER"
    printf 'FOLDERS=%s\nAPPLE_COMPAT=%s\nUPGRADE=%s\nNEW_HOSTNAME=%s\n' "$FOLDERS" "$APPLE_COMPAT" "$UPGRADE" "$(hostname)"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
check() { # description command...
  local d=$1; shift
  if "$@" >>"$LOG_FILE" 2>&1; then ok "$d"; else err "$d"; VERIFY_FAILS=$((VERIFY_FAILS + 1)); fi
}

uuid_mounted() { [[ $(findmnt -n -o UUID --mountpoint "$MOUNT_POINT" 2>/dev/null) == "$PART_UUID" ]]; }
fstab_has()    { grep -qE "^UUID=${PART_UUID}[[:space:]]+${MOUNT_POINT}[[:space:]]" /etc/fstab; }
user_write()   { local f="$MOUNT_POINT/.pinas-write-test.$$"; runuser -u "$SMB_USER" -- touch "$f" && runuser -u "$SMB_USER" -- rm -f "$f"; }
user_xattr() {
  local f="$MOUNT_POINT/.pinas-xattr-test.$$" v rc=0
  runuser -u "$SMB_USER" -- touch "$f" || return 1
  runuser -u "$SMB_USER" -- setfattr -n user.pinas -v ok "$f" || rc=1
  v=$(runuser -u "$SMB_USER" -- getfattr -n user.pinas --only-values "$f" 2>/dev/null) || rc=1
  rm -f "$f"
  (( rc == 0 )) && [[ $v == ok ]]
}
share_path_ok() { [[ $(testparm -s --section-name="$SHARE_NAME" --parameter-name=path 2>/dev/null) == "$MOUNT_POINT" ]]; }
apple_active()  { testparm -s --parameter-name="vfs objects" 2>/dev/null | grep -qw fruit; }
share_listed()  { smbclient -L //localhost -N -g 2>/dev/null | grep -q "^Disk|$SHARE_NAME|"; }
smb_login_rw() {
  local af="$TMP/smbauth" out
  ( umask 077; printf 'username = %s\npassword = %s\n' "$SMB_USER" "$SMB_PASSWORD" >"$af" )
  out=$(smbclient "//localhost/$SHARE_NAME" -A "$af" -m SMB3 -c "mkdir pinas_smb_test; rmdir pinas_smb_test" 2>&1) || true
  rm -f "$af"
  printf '%s\n' "$out"
  ! grep -q "NT_STATUS" <<<"$out"
}

verify_setup() {
  step "Verifying the NAS"
  VERIFY_FAILS=0
  check "Drive mounted at $MOUNT_POINT"                         uuid_mounted
  check "Drive listed in /etc/fstab (mounts at boot)"           fstab_has
  check "smbd service is running"                               systemctl is-active --quiet smbd
  check "smbd starts at boot"                                   systemctl is-enabled --quiet smbd
  check "Share [$SHARE_NAME] points to $MOUNT_POINT"            share_path_ok
  [[ $APPLE_COMPAT == yes ]] && check "Apple/iOS settings active (vfs fruit)" apple_active
  check "$SMB_USER can write to the drive"                      user_write
  check "$SMB_USER can set extended attributes (needed by iOS)" user_xattr
  check "Share is advertised by Samba"                          share_listed
  if [[ -n $SMB_PASSWORD ]]; then
    check "Log in over SMB and create a folder as $SMB_USER"    smb_login_rw
  fi
  if mountpoint -q "$MOUNT_POINT"; then
    say "  Space: $(df -h --output=size,used,avail "$MOUNT_POINT" | tail -n1 | awk '{print $3" free of "$1}')"
  fi
}

print_summary() {
  local host ips ip
  host=$(hostname)
  ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -vE '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' || true)
  printf '\n%s======================================================%s\n' "$C_B" "$C_0"
  if (( VERIFY_FAILS == 0 )); then
    printf '%s  Your NAS is ready.%s\n' "$C_B$C_G" "$C_0"
  else
    printf '%s  Finished with %d failed check(s). See %s%s\n' "$C_B$C_Y" "$VERIFY_FAILS" "$LOG_FILE" "$C_0"
  fi
  printf '%s======================================================%s\n' "$C_B" "$C_0"
  printf '  Log in as:   %s (Samba password)\n' "$SMB_USER"
  printf '  Windows:     \\\\%s.local\\%s\n' "$host" "$SHARE_NAME"
  for ip in $ips; do printf '               \\\\%s\\%s\n' "$ip" "$SHARE_NAME"; done
  printf '  macOS/Linux: smb://%s.local/%s\n' "$host" "$SHARE_NAME"
  for ip in $ips; do printf '               smb://%s/%s\n' "$ip" "$SHARE_NAME"; done
  printf '  iPhone/iPad: Files > ... > Connect to Server > smb://%s\n' "${ips%%$'\n'*}"
  printf '               choose "Registered User"\n\n'
  printf '  Next steps:\n'
  printf '   1. Reserve this IP for the Pi in your router (DHCP reservation).\n'
  printf '   2. Remote access: install Tailscale (see section 7 of the guide).\n'
  printf '      Never forward ports 445/139 on your router.\n'
  printf '   3. Keep a separate backup. A NAS on its own is not a backup.\n'
  printf '   Re-run checks any time with: sudo bash %s --verify\n\n' "$PROG"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
$PROG v$SCRIPT_VERSION: interactive Raspberry Pi NAS setup (drive + Samba + iOS support)

Usage: sudo bash $PROG [options]

  --dry-run       Ask all questions, then show commands and file diffs only
  --verify        Run the health checks against the saved setup and exit
  --config FILE   Non-interactive mode, answers read from FILE (KEY=value lines)
  --yes           With --config: skip the review screen
  --text          Use plain text prompts instead of whiptail menus
  -V, --version   Print the version and exit
  -h, --help      Show this help

Config file keys:
  ACTION=keep|format_part|wipe_disk   PART=/dev/sda1 or PART_UUID=...   DISK=/dev/sda
  MOUNT_POINT=/srv/nas  FS_LABEL=NASDATA  SHARE_NAME=NAS  SMB_USER=nasadmin
  CREATE_USER=yes|no  FOLDERS="Shared Backups Media"  APPLE_COMPAT=yes|no
  UPGRADE=yes|no  NEW_HOSTNAME=pinas  FIX_OWNERSHIP=yes|no
  CONFIRM_ERASE=/dev/sda   (required for format_part / wipe_disk; must match the target)
  SMB_PASSWORD_FILE=/root/smbpw   (or export PINAS_SMB_PASSWORD and use sudo -E)

Log: $LOG_FILE   Saved answers: $STATE_FILE
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --verify)  MODE="verify" ;;
      --config)  [[ -n ${2:-} ]] || die "--config needs a file"; CONFIG_FILE=$(readlink -f "$2"); shift ;;
      --yes|-y)  ASSUME_YES=1 ;;
      --text)    FORCE_TEXT=1 ;;
      -V|--version) printf '%s %s\n' "$PROG" "$SCRIPT_VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || { echo "Please run as root." >&2; exit 1; }
    if [[ -n ${PINAS_SMB_PASSWORD:-} ]]; then
      exec sudo --preserve-env=PINAS_SMB_PASSWORD bash "$(readlink -f "$0")" "$@"
    fi
    exec sudo bash "$(readlink -f "$0")" "$@"
  fi

  TMP=$(mktemp -d /tmp/pinas-setup.XXXXXX)
  trap cleanup EXIT
  trap 'on_error $LINENO' ERR
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  log "===== $PROG v$SCRIPT_VERSION started (mode=$MODE dry_run=$DRY_RUN) ====="

  preflight
  init_ui

  if [[ $MODE == verify ]]; then
    [[ -r $STATE_FILE ]] || die "No saved setup found ($STATE_FILE). Run the wizard first."
    load_kv_file "$STATE_FILE"
    STEP_TOTAL=1
    verify_setup; print_summary
    exit $(( VERIFY_FAILS > 0 ))
  fi

  if [[ -n $CONFIG_FILE ]]; then
    load_kv_file "$CONFIG_FILE"
    prepare_noninteractive
    if (( ! ASSUME_YES )) && [[ -r /dev/tty ]]; then confirm_apply; fi
  else
    if [[ -r $STATE_FILE ]]; then
      load_kv_file "$STATE_FILE"
      local choice
      until choice=$(ui_menu "Existing setup found" "This Pi was set up before (share [$SHARE_NAME] at $MOUNT_POINT).\nWhat would you like to do?" "VERIFY" \
            "VERIFY"      "Run the health checks only" \
            "RECONFIGURE" "Run the wizard again (saved answers are the defaults)"); do confirm_quit; done
      if [[ $choice == VERIFY ]]; then
        clear 2>/dev/null || true
        STEP_TOTAL=1; verify_setup; print_summary; exit $(( VERIFY_FAILS > 0 ))
      fi
    fi
    q_welcome
    q_drive
    q_mount_point
    q_label
    q_share
    q_user
    q_password
    q_folders
    q_options
    q_fix_owner
    confirm_apply
  fi
  confirm_erase
  (( USE_WT )) && clear 2>/dev/null || true

  (( DRY_RUN )) && say "${C_B}${C_Y}DRY RUN: nothing below is executed or written.${C_0}"
  apply_packages
  apply_system
  apply_drive
  apply_mount
  apply_folders
  apply_samba_user
  apply_samba_conf
  if (( DRY_RUN )); then
    step "Verifying the NAS"
    say "  (skipped in dry-run)"
    say ""; say "Dry run complete. Run again without --dry-run to apply."
    exit 0
  fi
  verify_setup
  save_state
  print_summary

  if [[ -z $CONFIG_FILE ]] && ui_yesno "Reboot?" "Setup is complete.\n\nReboot now to confirm the drive and Samba come back on their own?\nAfterwards, reconnect and run:\n\n  sudo bash $PROG --verify" no "Reboot" "Not now"; then
    say "Rebooting..."; systemctl reboot
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
