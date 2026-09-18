#!/bin/bash
#
# apt-auto-updates.sh
#
# Configures automatic APT updates and reboots via unattended-upgrades.
# Uses one broad origin policy so all configured APT sources are covered.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

 # load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

ensure_packages_installed unattended-upgrades smartmontools

TO_EMAIL=$(get_notification_email)

select_reboot_window() {
  local virtualization

  REBOOT_MIN_MINUTES=60
  REBOOT_MAX_MINUTES=239

  # Check the local Proxmox installation first, including nested PVE hosts.
  if is_proxmox; then
    REBOOT_MAX_MINUTES=90
    log_debug "Proxmox VE host detected; reboot window is 01:00–01:30 America/New_York."
  elif command -v systemd-detect-virt >/dev/null 2>&1; then
    # In this environment, all KVM/QEMU guests are hosted by Proxmox.
    # No virtualization is a normal nonzero exit; common.sh enables set -e.
    virtualization=$(systemd-detect-virt --vm 2>/dev/null || true)
    case "$virtualization" in
      kvm|qemu)
        REBOOT_MIN_MINUTES=105
        log_debug "KVM/QEMU guest detected; reboot window is 01:45–03:59 America/New_York."
        ;;
    esac
  fi
}

reboot_time_is_valid() {
  local total_minutes

  [[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  # Leading zeroes in HH:MM must be interpreted as decimal, not octal.
  total_minutes=$((10#${REBOOT_TIME:0:2} * 60 + 10#${REBOOT_TIME:3:2}))
  ((total_minutes >= REBOOT_MIN_MINUTES && total_minutes <= REBOOT_MAX_MINUTES))
}

randomize_reboot_time() {
  local range_length random_limit rand_minutes total_minutes reboot_hour reboot_minute

  # Include both endpoints: 31 host, 135 guest, or 180 general-purpose minutes.
  range_length=$((REBOOT_MAX_MINUTES - REBOOT_MIN_MINUTES + 1))
  # RANDOM yields 0–32767; reject the remainder to avoid modulo bias.
  random_limit=$((32768 - 32768 % range_length))
  while :; do
    rand_minutes=$RANDOM
    if ((rand_minutes < random_limit)); then
      break
    fi
  done
  total_minutes=$((REBOOT_MIN_MINUTES + rand_minutes % range_length))
  reboot_hour=$((total_minutes / 60))
  reboot_minute=$((total_minutes % 60))
  printf -v REBOOT_TIME "%02d:%02d" "$reboot_hour" "$reboot_minute"
  log_info "Automatic reboot window randomized; this host will reboot when needed at approximately $REBOOT_TIME America/New_York."
}

select_reboot_window

# Reuse an active configured time only while it remains in this machine's window.
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && grep -q '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time' /etc/apt/apt.conf.d/50unattended-upgrades; then
  REBOOT_TIME=$(grep '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time' /etc/apt/apt.conf.d/50unattended-upgrades | sed 's/.*"\([^"]*\)".*/\1/')
  if reboot_time_is_valid; then
    log_debug "Using existing reboot time: $REBOOT_TIME America/New_York"
  else
    log_warn "Existing unattended-upgrades reboot time is invalid or outside this machine's reboot window: $REBOOT_TIME; choosing a new randomized time."
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
  log_debug "unattended-upgrades.service not found; scheduled upgrades are handled by apt-daily-upgrade.timer."
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
