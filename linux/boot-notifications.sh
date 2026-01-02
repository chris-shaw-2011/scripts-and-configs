#!/bin/bash
#
# boot-notifications.sh
#
# Installs notification scripts and systemd services for boot and reboot events.
# Sends email notifications after boot and before reboot/shutdown.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

TO_EMAIL=$(get_notification_email)

log_debug "Creating notification scripts (boot/reboot)..."

NOTIFY_BOOT=$(cat <<'EOF'
#!/bin/bash
HOSTNAME=$(hostname)
NOW=$(date)
UPTIME=$(uptime -s)
SUBJECT="BOOTED: ${HOSTNAME}"
BODY="The server ${HOSTNAME} has BOOTED UP at ${NOW}.\nUptime started at: ${UPTIME}."
TO="$TO_EMAIL"
while true; do
  echo -e "${BODY}" | mail -s "${SUBJECT}" "$TO" && break
  echo "[$(date)] Mail send failed, retrying in 5s..."
  sleep 5
done
EOF
)

NOTIFY_REBOOT=$(cat <<'EOF'
#!/bin/bash
HOSTNAME=$(hostname)
NOW=$(date)
UPTIME=$(uptime -p)
SUBJECT="REBOOTING: ${HOSTNAME}"
BODY="The server ${HOSTNAME} is about to REBOOT or SHUT DOWN at ${NOW}.\nIt has been ${UPTIME}."
TO="$TO_EMAIL"
echo -e "${BODY}" | mail -s "${SUBJECT}" "$TO"
EOF
)

# Replace $TO_EMAIL placeholder in NOTIFY_BOOT
NOTIFY_BOOT=$(echo "$NOTIFY_BOOT" | sed "s|\$TO_EMAIL|$TO_EMAIL|g")

CHANGED=0
if write_file_if_changed /usr/local/bin/notify-after-boot.sh "$NOTIFY_BOOT"; then
  : # no change, do nothing
else
  CHANGED=1
  log_debug "Setting execute permissions on /usr/local/bin/notify-after-boot.sh"
  chmod +x /usr/local/bin/notify-after-boot.sh
fi

if write_file_if_changed /usr/local/bin/notify-before-reboot.sh "$NOTIFY_REBOOT"; then
  : # no change, do nothing
else
  CHANGED=1
  log_debug "Setting execute permissions on /usr/local/bin/notify-before-reboot.sh"
  chmod +x /usr/local/bin/notify-before-reboot.sh
fi

log_debug "Creating systemd service units (boot/reboot)..."

NOTIFY_AFTER_BOOT=$(cat <<'EOF'
[Unit]
Description=Send email AFTER boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/notify-after-boot.sh

[Install]
WantedBy=multi-user.target
EOF
)

NOTIFY_BEFORE_REBOOT=$(cat <<'EOF'
[Unit]
Description=Send email BEFORE system shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/notify-before-reboot.sh
TimeoutStartSec=0

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF
)

write_file_if_changed /etc/systemd/system/notify-after-boot.service "$NOTIFY_AFTER_BOOT" || CHANGED=1
write_file_if_changed /etc/systemd/system/notify-before-reboot.service "$NOTIFY_BEFORE_REBOOT" || CHANGED=1

if [ "$CHANGED" -eq 1 ]; then
  log_info "Reloading systemd configuration..."
  systemctl daemon-reexec
  systemctl daemon-reload
else
  log_debug "No systemd reloads needed"
fi

# Enable services only if they're not already enabled
if ! systemctl is-enabled --quiet notify-after-boot.service 2>/dev/null; then
  log_info "Enabling notify-after-boot.service"
  systemctl enable notify-after-boot.service
  CHANGED=1
else
  log_debug "notify-after-boot.service already enabled"
fi

if ! systemctl is-enabled --quiet notify-before-reboot.service 2>/dev/null; then
  log_info "Enabling notify-before-reboot.service"
  systemctl enable notify-before-reboot.service
  CHANGED=1
else
  log_debug "notify-before-reboot.service already enabled"
fi

if [ "$CHANGED" -eq 1 ]; then
  log_info "Boot notification configuration changes applied"
else
  log_info "No boot notification configuration changes needed"
fi

log_completed_execution
