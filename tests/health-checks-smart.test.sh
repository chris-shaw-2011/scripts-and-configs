#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/linux/health-checks.sh"

smart_device_candidates() {
  awk '$2=="disk" && $1 !~ /^zd[0-9]+$/ {print "/dev/"$1}' "$@"
}

smart_status_is_healthy() {
  local output=$1
  local condition

  condition=$(awk '
    /if ! echo "\$OUT" \| grep -Eq/ {
      print
      exit
    }
  ' "$SCRIPT")

  if [ -z "$condition" ]; then
    echo "Could not find SMART health condition in $SCRIPT" >&2
    return 2
  fi

  if ! echo "$condition" | grep -q "SMART Health Status: OK"; then
    return 1
  fi

  if echo "$output" | grep -Eq "(overall-health self-assessment test result: PASSED|SMART Health Status: OK)"; then
    return 0
  fi

  return 1
}

ok_status='smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-124-generic] (local build)

=== START OF READ SMART DATA SECTION ===
SMART Health Status: OK'

if ! smart_status_is_healthy "$ok_status"; then
  echo "Expected SMART Health Status: OK to be treated as healthy" >&2
  exit 1
fi

passed_status='=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED'

if ! smart_status_is_healthy "$passed_status"; then
  echo "Expected overall-health self-assessment PASSED to be treated as healthy" >&2
  exit 1
fi

lsblk_output='sda disk
nvme0n1 disk
zd0 disk
zd16 disk
rpool part'

devices=$(smart_device_candidates <<< "$lsblk_output")

if echo "$devices" | grep -q '^/dev/zd'; then
  echo "Expected ZFS zvol devices to be excluded from SMART checks" >&2
  exit 1
fi

if ! echo "$devices" | grep -qx '/dev/sda'; then
  echo "Expected physical disk /dev/sda to remain in SMART checks" >&2
  exit 1
fi

if ! echo "$devices" | grep -qx '/dev/nvme0n1'; then
  echo "Expected physical disk /dev/nvme0n1 to remain in SMART checks" >&2
  exit 1
fi
