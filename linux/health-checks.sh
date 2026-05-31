#!/bin/bash
#
# health-checks.sh
#
# Installs DAILY and WEEKLY health check scripts with systemd timers.
#
# DAILY health alerts:
#   - Failed systemd units
#   - Low disk space on local filesystems
#   - ZFS pool health and high usage (if pools exist)
#   - Reboot-required flag
#
# WEEKLY maintenance alerts:
#   - ZFS scrubs and pool health
#   - SMART disk health
#   - apt autoremove/clean

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

TO_EMAIL=$(get_notification_email)

CHANGED=0

log_debug "Creating DAILY health check script..."

DAILY_HEALTH_CHECK=$(cat <<'EOF'
#!/bin/bash
TO="__TO_EMAIL__"
HOSTNAME=$(hostname)
REPORT=""
ISSUES=0

append() {
  REPORT+="$1"$'\n'
}

# Failed systemd units
FAILED=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
if [ -n "$FAILED" ]; then
  ISSUES=1
  append "=== Failed systemd units ==="
  append "$FAILED"
fi

# Disk space usage on local filesystems only (exclude tmpfs/devtmpfs and network/fuse/autofs)
DISK_WARN=""
while read -r fs size used avail pcent mount; do
  pct=${pcent%%%}
  if [ "$pct" -ge 90 ]; then
    DISK_WARN+=$'\n'"$fs $size $used $avail $pcent $mount"
  fi
done < <(
  df -h \
    -x tmpfs \
    -x devtmpfs \
    -x cifs \
    -x smbfs \
    -x nfs \
    -x nfs4 \
    -x fuse \
    -x fuseblk \
    -x fuse.sshfs \
    -x autofs \
  | awk 'NR>1 {print $1, $2, $3, $4, $5, $6}'
)

if [ -n "$DISK_WARN" ]; then
  ISSUES=1
  append "=== Low disk space on local filesystems (>=90% used) ==="
  append "$DISK_WARN"
fi

# ZFS pool health and capacity (if ZFS present and pools exist)
if command -v zpool >/dev/null 2>&1; then
  POOLS=$(zpool list -H -o name 2>/dev/null || true)
  if [ -n "$POOLS" ]; then
    ZSTATUS=$(zpool status -x 2>&1 || true)
    if ! echo "$ZSTATUS" | grep -q "all pools are healthy"; then
      ISSUES=1
      append "=== ZFS pool health issues ==="
      append "$ZSTATUS"
    fi

    ZCAP_WARN=""
    while read -r name cap; do
      cap_pct=${cap%%%}
      if [ "$cap_pct" -ge 80 ]; then
        ZCAP_WARN+=$'\n'"$name $cap"
      fi
    done < <(zpool list -H -o name,capacity 2>/dev/null || true)

    if [ -n "$ZCAP_WARN" ]; then
      ISSUES=1
      append "=== ZFS pool high usage (>=80% capacity) ==="
      append "$ZCAP_WARN"
    fi
  fi
fi

# Reboot required flag
if [ -f /var/run/reboot-required ]; then
  ISSUES=1
  append "=== Reboot required ==="
  append "$(cat /var/run/reboot-required 2>/dev/null || true)"
  if [ -f /var/run/reboot-required.pkgs ]; then
    append "Packages:"
    append "$(cat /var/run/reboot-required.pkgs 2>/dev/null || true)"
  fi
fi

if [ "$ISSUES" -eq 1 ]; then
  SUBJECT="HEALTH ALERT (daily): ${HOSTNAME}"
  echo -e "$REPORT" | mail -s "$SUBJECT" "$TO"
fi
EOF
)

# Replace placeholder with actual email
DAILY_HEALTH_CHECK=$(echo "$DAILY_HEALTH_CHECK" | sed "s|__TO_EMAIL__|$TO_EMAIL|g")
if write_file_if_changed /usr/local/bin/daily-health-check.sh "$DAILY_HEALTH_CHECK"; then
  :  # no change, do nothing
else
  CHANGED=1
  log_debug "Setting execute permissions on /usr/local/bin/daily-health-check.sh"
  chmod +x /usr/local/bin/daily-health-check.sh
fi

log_debug "Creating WEEKLY maintenance script..."

WEEKLY_MAINTENANCE=$(cat <<'EOF'
#!/bin/bash
TO="__TO_EMAIL__"
HOSTNAME=$(hostname)
REPORT=""
ISSUES=0

append() {
  REPORT+="$1"$'\n'
}

append "Weekly maintenance on ${HOSTNAME} at $(date)"

############################################
# ZFS scrubs + health check (if ZFS present)
############################################
if command -v zpool >/dev/null 2>&1; then
  POOLS=$(zpool list -H -o name 2>/dev/null || true)
  if [ -n "$POOLS" ]; then
    for p in $POOLS; do
      OUT=$(zpool scrub "$p" 2>&1 || true)
      if [ -n "$OUT" ]; then
        ISSUES=1
        append ""
        append "=== ZFS scrub command issue on pool: $p ==="
        append "$OUT"
      fi
    done

    ZSTATUS=$(zpool status -x 2>&1 || true)
    if ! echo "$ZSTATUS" | grep -q "all pools are healthy"; then
      ISSUES=1
      append ""
      append "=== ZFS reports non-healthy pools ==="
      append "$ZSTATUS"
    fi
  fi
fi

########################
# SMART health checking
########################
if command -v smartctl >/dev/null 2>&1; then
  DEVICES=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1 !~ /^zd[0-9]+$/ {print "/dev/"$1}')
  for d in $DEVICES; do
    OUT=$(smartctl -H "$d" 2>&1 || true)

    if echo "$OUT" | grep -q "SMART support is: Unavailable"; then
      continue
    fi

    if ! echo "$OUT" | grep -Eq "(overall-health self-assessment test result: PASSED|SMART Health Status: OK)"; then
      ISSUES=1
      append ""
      append "=== SMART health issue on device: $d ==="
      append "$OUT"
    fi
  done
fi

############################################
# Kernel / package cleanup (autoremove/clean)
############################################
append ""
append "=== apt autoremove/clean ==="
if pgrep -x unattended-upgrade >/dev/null 2>&1; then
  append "unattended-upgrade is running; skipping apt autoremove/clean this week."
else
  AUTOREMOVE_OUT=$(apt-get -y autoremove --purge 2>&1)
  RET1=$?
  CLEAN_OUT=$(apt-get -y clean 2>&1)
  RET2=$?

  if [ $RET1 -ne 0 ] || [ $RET2 -ne 0 ]; then
    ISSUES=1
    append "apt-get autoremove/clean returned a non-zero exit code."
  fi

  append "apt-get autoremove --purge output:"
  append "$AUTOREMOVE_OUT"
  append ""
  append "apt-get clean output:"
  append "$CLEAN_OUT"
fi

############################################
# Send email ONLY if any issues were detected
############################################
if [ "$ISSUES" -ne 0 ]; then
  SUBJECT="WEEKLY MAINTENANCE ISSUES: ${HOSTNAME}"
  echo -e "$REPORT" | mail -s "$SUBJECT" "$TO"
fi
EOF
)

# Replace placeholder with actual email
WEEKLY_MAINTENANCE=$(echo "$WEEKLY_MAINTENANCE" | sed "s|__TO_EMAIL__|$TO_EMAIL|g")
if write_file_if_changed /usr/local/bin/weekly-maintenance.sh "$WEEKLY_MAINTENANCE"; then
  :  # no change, do nothing
else
  CHANGED=1
  log_debug "Setting execute permissions on /usr/local/bin/weekly-maintenance.sh"
  chmod +x /usr/local/bin/weekly-maintenance.sh
fi

log_debug "Creating systemd service/timer units..."

DAILY_SERVICE=$(cat <<'EOF'
[Unit]
Description=Daily health check email (only on issues)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-health-check.sh
EOF
)

DAILY_TIMER=$(cat <<'EOF'
[Unit]
Description=Run daily health check (only email on issues)

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
)

WEEKLY_SERVICE=$(cat <<'EOF'
[Unit]
Description=Weekly maintenance email (only on issues)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/weekly-maintenance.sh
EOF
)

WEEKLY_TIMER=$(cat <<'EOF'
[Unit]
Description=Run weekly maintenance (only email on issues)

[Timer]
OnCalendar=Sun *-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
)

write_file_if_changed /etc/systemd/system/daily-health-check.service "$DAILY_SERVICE" || CHANGED=1
write_file_if_changed /etc/systemd/system/daily-health-check.timer "$DAILY_TIMER" || CHANGED=1
write_file_if_changed /etc/systemd/system/weekly-maintenance.service "$WEEKLY_SERVICE" || CHANGED=1
write_file_if_changed /etc/systemd/system/weekly-maintenance.timer "$WEEKLY_TIMER" || CHANGED=1

if [ "$CHANGED" -eq 1 ]; then
  log_info "Reloading systemd configuration..."
  systemctl daemon-reload  
else
  log_debug "No health check configuration changes"
fi

# Enable timers only if not already enabled
if ! systemctl is-enabled --quiet daily-health-check.timer 2>/dev/null; then
  log_info "Enabling daily-health-check.timer"
  systemctl enable --now daily-health-check.timer
else
  log_debug "daily-health-check.timer already enabled"
fi

if ! systemctl is-enabled --quiet weekly-maintenance.timer 2>/dev/null; then
  log_info "Enabling weekly-maintenance.timer"
  systemctl enable --now weekly-maintenance.timer
else
  log_debug "weekly-maintenance.timer already enabled"
fi

if [ "$CHANGED" -eq 1 ]; then
  log_info "All health check configuration changes applied"
else
  log_info "No health check configuration changes needed"
fi

log_completed_execution
