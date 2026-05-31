#!/bin/bash
#
# apt-auto-updates.sh
#
# Configures automatic APT updates and reboots via unattended-upgrades.
# Adapts configuration based on whether this is a Proxmox or generic Debian/Ubuntu system.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

 # load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

ensure_packages_installed unattended-upgrades smartmontools

TO_EMAIL=$(get_notification_email)

randomize_reboot_time() {
  local rand_minutes total_minutes reboot_hour reboot_minute

  # Choose a random reboot time between 01:00 and 03:59 (America/New_York)
  # 1:00 = 60 minutes after midnight; range length = 180 minutes (3 hours)
  rand_minutes=$((RANDOM % 180))  # 0–179
  total_minutes=$((60 + rand_minutes))  # 60–239
  reboot_hour=$((total_minutes / 60))    # 1–3
  reboot_minute=$((total_minutes % 60))  # 0–59
  printf -v REBOOT_TIME "%02d:%02d" "$reboot_hour" "$reboot_minute"
  log_info "Automatic reboot window randomized; this host will reboot when needed at approximately $REBOOT_TIME America/New_York."
}

# Check if reboot time is already configured, otherwise randomize it once.
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && grep -q 'Unattended-Upgrade::Automatic-Reboot-Time' /etc/apt/apt.conf.d/50unattended-upgrades; then
  REBOOT_TIME=$(grep 'Unattended-Upgrade::Automatic-Reboot-Time' /etc/apt/apt.conf.d/50unattended-upgrades | sed 's/.*"\([^"]*\)".*/\1/')
  if [[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log_debug "Using existing reboot time: $REBOOT_TIME America/New_York"
  else
    log_warn "Existing unattended-upgrades reboot time is invalid: $REBOOT_TIME; choosing a new randomized time."
    randomize_reboot_time
  fi
else
  randomize_reboot_time
fi

log_debug "Creating unattended-upgrades configuration..."

CHANGED=0
CONFIG_50=$(cat <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=*";
};

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Mail "$TO_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::SyslogEnable "true";
EOF
)

write_file_if_changed /etc/apt/apt.conf.d/50unattended-upgrades "$CONFIG_50" || CHANGED=1

CONFIG_20=$(cat <<EOF
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
)

write_file_if_changed /etc/apt/apt.conf.d/20auto-upgrades "$CONFIG_20" || CHANGED=1

log_debug "Enabling unattended-upgrades services/timers (where present)..."

if systemctl list-unit-files | grep -q '^unattended-upgrades.service'; then
  if ! systemctl is-enabled --quiet unattended-upgrades.service 2>/dev/null; then
    log_info "Enabling unattended-upgrades.service"
    systemctl enable --now unattended-upgrades.service
    CHANGED=1
  else
    log_debug "unattended-upgrades.service already enabled"
  fi
else
  log_warn "unattended-upgrades.service not found; skipping."
fi

if systemctl list-unit-files | grep -q '^apt-daily.timer'; then
  if ! systemctl is-enabled --quiet apt-daily.timer 2>/dev/null; then
    log_info "Enabling apt-daily.timer"
    systemctl enable --now apt-daily.timer || log_warn "Failed to enable apt-daily.timer."
    CHANGED=1
  else
    log_debug "apt-daily.timer already enabled"
  fi
else
  log_warn "apt-daily.timer not found; skipping."
fi

if systemctl list-unit-files | grep -q '^apt-daily-upgrade.timer'; then
  if ! systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
    log_info "Enabling apt-daily-upgrade.timer"
    systemctl enable --now apt-daily-upgrade.timer || log_warn "Failed to enable apt-daily-upgrade.timer."
    CHANGED=1
  else
    log_debug "apt-daily-upgrade.timer already enabled"
  fi
else
  log_warn "apt-daily-upgrade.timer not found; skipping."
fi

if [ "$CHANGED" -eq 1 ]; then
  log_info "All unattended-upgrades configuration changes applied"
else
  log_info "No unattended-upgrades configuration changes needed"
fi

log_completed_execution
