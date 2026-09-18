#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run the installer against temporary APT files with its real write/log/detection
# helpers, but no package installation, notification prompts, or service changes.
mkdir -p "$TMP_DIR/apt"
sed "s|/etc/apt/apt.conf.d|$TMP_DIR/apt|g" \
  "$REPO_DIR/linux/apt-auto-updates.sh" > "$TMP_DIR/apt-auto-updates.sh"
{
  printf '%s\n' 'set -eu -o pipefail' 'DEBUG=1' \
    'COLOR_DEBUG=""' 'COLOR_WARN=""' 'COLOR_RESET=""' 'CALLING_SCRIPT=apt-auto-updates.test.sh'
  for helper in log_info log_warn log_debug log_completed_execution timestamp \
    backup_if_exists write_file_if_changed is_proxmox; do
    sed -n "/^$helper()/,/^}/p" "$REPO_DIR/linux/common.sh"
  done
  cat <<'EOF'
ensure_packages_installed() { :; }
get_notification_email() { echo 'admin@example.com'; }
dpkg() {
  [[ "$1" = -l ]] || return 1
  if [[ "$HOST_PACKAGE" = installed ]]; then
    echo 'ii proxmox-ve 9.2 all Proxmox VE'
  else
    echo 'rc proxmox-ve 9.2 all Proxmox VE'
  fi
}
command() {
  if [[ "$*" = '-v systemd-detect-virt' && "$VM_TYPE" = missing ]]; then
    return 1
  fi
  builtin command "$@"
}
systemd-detect-virt() {
  [[ "$1" = --vm ]] || return 1
  echo "$VM_TYPE"
  [[ "$VM_TYPE" != none && "$VM_TYPE" != failure ]]
}
systemctl() {
  case "$1" in
    list-unit-files)
      printf '%s\n' 'unattended-upgrades.service enabled' \
        'apt-daily.timer enabled' 'apt-daily-upgrade.timer enabled'
      ;;
    is-enabled) return 0 ;;
    *) return 1 ;;
  esac
}
EOF
} | sed "s|/etc/pve/.version|$TMP_DIR/pve-version|g" > "$TMP_DIR/common.sh"

run_case() {
  local label=$1 host_source=$2 virtualization=$3 existing=$4 minimum=$5 maximum=$6
  local reboot_time minutes first_config first_periodic backup_count
  local backups=()

  rm -f "$TMP_DIR"/apt/* "$TMP_DIR/pve-version"
  export HOST_PACKAGE=absent VM_TYPE="$virtualization"
  case "$host_source" in
    file) touch "$TMP_DIR/pve-version" ;;
    package) HOST_PACKAGE=installed ;;
  esac
  if [[ "$existing" != missing ]]; then
    printf '%s\n' "Unattended-Upgrade::Automatic-Reboot-Time \"$existing\";" \
      > "$TMP_DIR/apt/50unattended-upgrades"
  fi

  bash "$TMP_DIR/apt-auto-updates.sh" > "$TMP_DIR/output" 2>&1 \
    || fail "$label: installer failed ($(cat "$TMP_DIR/output"))"
  reboot_time=$(sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\([^"]*\)";.*/\1/p' \
    "$TMP_DIR/apt/50unattended-upgrades")
  [[ "$reboot_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || fail "$label: invalid generated time '$reboot_time'"
  minutes=$((10#${reboot_time:0:2} * 60 + 10#${reboot_time:3:2}))
  ((minutes >= minimum && minutes <= maximum)) \
    || fail "$label: '$reboot_time' is outside the expected window"
  if [[ "$existing" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    minutes=$((10#${existing:0:2} * 60 + 10#${existing:3:2}))
    if ((minutes >= minimum && minutes <= maximum)); then
      [[ "$reboot_time" = "$existing" ]] || fail "$label: valid time was replaced"
    fi
  fi

  first_config=$(cat "$TMP_DIR/apt/50unattended-upgrades")
  first_periodic=$(cat "$TMP_DIR/apt/20auto-upgrades")
  shopt -s nullglob
  backups=("$TMP_DIR"/apt/*.bak)
  backup_count=${#backups[@]}
  bash "$TMP_DIR/apt-auto-updates.sh" > "$TMP_DIR/output" 2>&1 \
    || fail "$label: rerun failed"
  [[ "$(cat "$TMP_DIR/apt/50unattended-upgrades")" = "$first_config" ]] \
    || fail "$label: reboot configuration changed on rerun"
  [[ "$(cat "$TMP_DIR/apt/20auto-upgrades")" = "$first_periodic" ]] \
    || fail "$label: periodic configuration changed on rerun"
  backups=("$TMP_DIR"/apt/*.bak)
  [[ ${#backups[@]} = "$backup_count" ]] || fail "$label: rerun created a backup"
  grep -q 'No unattended-upgrades configuration changes needed' "$TMP_DIR/output" \
    || fail "$label: rerun reported changes"
}

run_case 'PVE filesystem detection' file none missing 60 90
run_case 'PVE package detection and precedence over KVM' package kvm missing 60 90
run_case 'KVM detection' absent kvm missing 105 239
run_case 'QEMU detection' absent qemu missing 105 239
run_case 'Bare metal' absent none missing 60 239
run_case 'Other hypervisor' absent vmware missing 60 239
run_case 'Missing detector' absent missing missing 60 239
run_case 'Detector failure' absent failure missing 60 239

for time in 01:00 01:08 01:30; do
  run_case "PVE reuse $time" package none "$time" 60 90
done
for time in 00:59 01:31 03:59; do
  run_case "PVE replace $time" package none "$time" 60 90
done
for time in 01:45 02:09 03:59; do
  run_case "Guest reuse $time" absent kvm "$time" 105 239
done
for time in 01:00 01:44 04:00; do
  run_case "Guest replace $time" absent qemu "$time" 105 239
done
for time in 01:00 03:59; do
  run_case "General reuse $time" absent none "$time" 60 239
done
for time in 00:59 04:00 24:00 01:60 1:00 garbage; do
  run_case "General replace $time" absent none "$time" 60 239
done

# Exhaustively check every minute of the day against each inclusive window.
eval "$(sed -n '/^reboot_time_is_valid()/,/^}/p' "$REPO_DIR/linux/apt-auto-updates.sh")"
for window in '60 90' '105 239' '60 239'; do
  read -r REBOOT_MIN_MINUTES REBOOT_MAX_MINUTES <<< "$window"
  for ((minute=0; minute<1440; minute++)); do
    printf -v REBOOT_TIME '%02d:%02d' "$((minute / 60))" "$((minute % 60))"
    if reboot_time_is_valid; then
      ((minute >= REBOOT_MIN_MINUTES && minute <= REBOOT_MAX_MINUTES)) \
        || fail "$window: incorrectly accepted $REBOOT_TIME"
    else
      ((minute < REBOOT_MIN_MINUTES || minute > REBOOT_MAX_MINUTES)) \
        || fail "$window: incorrectly rejected $REBOOT_TIME"
    fi
  done
done

# Make RANDOM an ordinary variable in a subshell to force the generator's
# endpoint draws. This checks actual generation without probabilistic tests.
eval "$(sed -n '/^randomize_reboot_time()/,/^}/p' "$REPO_DIR/linux/apt-auto-updates.sh")"
log_info() { :; }
(
  unset RANDOM
  for window in '60 90' '105 239' '60 239'; do
    read -r REBOOT_MIN_MINUTES REBOOT_MAX_MINUTES <<< "$window"
    RANDOM=0
    randomize_reboot_time
    minutes=$((10#${REBOOT_TIME:0:2} * 60 + 10#${REBOOT_TIME:3:2}))
    [[ "$minutes" = "$REBOOT_MIN_MINUTES" ]] || fail "$window: minimum cannot be generated"
    RANDOM=$((REBOOT_MAX_MINUTES - REBOOT_MIN_MINUTES))
    randomize_reboot_time
    minutes=$((10#${REBOOT_TIME:0:2} * 60 + 10#${REBOOT_TIME:3:2}))
    [[ "$minutes" = "$REBOOT_MAX_MINUTES" ]] || fail "$window: maximum cannot be generated"
  done
)

echo 'APT reboot scheduling tests passed.'
