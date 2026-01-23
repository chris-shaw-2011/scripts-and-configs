#!/bin/bash
#
# set-timezone.sh
#
# Set the system timezone to America/New_York (if timedatectl available).

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

 # load shared helpers and require root
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

TARGET_TZ="America/New_York"

if command -v timedatectl >/dev/null 2>&1; then
  CUR_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)

  if [ "$CUR_TZ" = "$TARGET_TZ" ]; then
    log_info "Timezone already set to $TARGET_TZ; nothing to do."
  else
    timedatectl set-timezone "$TARGET_TZ"
  fi
else
  if [ -f /etc/timezone ]; then
    CUR_TZ=$(cat /etc/timezone 2>/dev/null || echo unknown)

    if [ "$CUR_TZ" = "$TARGET_TZ" ]; then
      log_info "/etc/timezone already set to $TARGET_TZ; nothing to do."
    else
      log_warn "timedatectl not found and /etc/timezone is not $TARGET_TZ; skipping timezone configuration."
    fi
  else
    log_warn "timedatectl and /etc/timezone not available; skipping timezone configuration."
  fi
fi

log_completed_execution
