#!/bin/bash
#
# setup.sh
#
# Main orchestrator script that runs all component setup scripts.
#
# GOALS / POLICY:
#
# - Target environments:
#   - Proxmox VE (9.x)
#   - Generic Debian / Ubuntu servers and desktops
#
# - Keep the system fully up to date and automated WITHOUT major distro upgrades:
#   - Enable unattended APT updates for all appropriate origins.
#   - On Proxmox, use permissive origin patterns so repo metadata changes do not break updates.
#   - Allow minor / point Proxmox upgrades (e.g., 9.0 → 9.1), but NOT major OS jumps.
#   - Automatically reboot when required, within a randomized window
#     between 01:00–04:00 America/New_York (per-host randomization).
#
# - Authorization / reboot behavior:
#   - Install or update a polkit rule that allows all regular users (UID ≥ 1000)
#     to reboot the system via systemd/logind WITHOUT sudo.
#   - This is required for remote sessions (SSH, XRDP) where no interactive
#     polkit authentication agent may be present.
#
# - Email notifications via Gmail (msmtp):
#   - Always send emails on BOOT and before REBOOT / SHUTDOWN.
#   - Subjects always include the hostname.
#   - unattended-upgrades sends mail only on changes/errors (MailReport=on-change).
#
#   - DAILY health alert (only when issues exist):
#       * Failed systemd units
#       * Low disk space on local filesystems (network/FUSE excluded)
#       * ZFS pool health or high usage (only if pools exist)
#       * Reboot-required flag
#
#   - WEEKLY maintenance alert (only when issues exist):
#       * ZFS scrub or pool health problems
#       * SMART disk health failures
#       * apt autoremove / clean errors
#
#   - No "everything is OK" emails are sent.
#
# - ZFS / SMART behavior:
#   - If ZFS tools or pools are missing, ZFS checks are skipped silently.
#   - If SMART is unavailable for a device, that device is skipped.
#
# - Timezone / timestamps:
#   - Force system timezone to America/New_York when possible.
#   - All email timestamps use the system timezone.
#
# - Design principles:
#   - Script is idempotent and safe to re-run.
#   - Important config files are backed up with timestamped .bak suffixes.
#   - Prefer systemd services/timers over cron where possible.
#   - Each sub-script is independent and can be run separately.
#
# To download and run this script:
# curl -sSL https://gist.githubusercontent.com/chris-shaw-2011/9b78ea951d01c05d41ad7ce5bad4e13e/raw/setup-auto-updates-and-notifications.sh \
#   -o ~/setup-auto-updates-and-notifications.sh && \
#   chmod +x ~/setup-auto-updates-and-notifications.sh && \
#   sudo ~/setup-auto-updates-and-notifications.sh

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load shared helpers and require root (forward args to common.sh)
. "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"

log_info "======================================================================"
log_info "Linux Desktop/Server Setup Script"
log_info "======================================================================"
log_info ""

# Run sub-scripts in order
log_info "Step 1: Setting up polkit reboot rule..."
"$SCRIPT_DIR/polkit-reboot.sh" "$@"
log_info ""

log_info "Step 2: Setting system timezone..."
"$SCRIPT_DIR/set-timezone.sh" "$@"
log_info ""
log_info ""

log_info "Step 3: Configuring msmtp and email..."
"$SCRIPT_DIR/msmtp-gmail.sh" "$@"
log_info ""

log_info "Step 4: Configuring APT automatic updates..."
"$SCRIPT_DIR/apt-auto-updates.sh" "$@"
log_info ""

log_info "Step 5: Setting up boot/reboot notifications..."
"$SCRIPT_DIR/boot-notifications.sh" "$@"
log_info ""

log_info "Step 6: Setting up daily/weekly health checks..."
"$SCRIPT_DIR/health-checks.sh" "$@"
log_info ""

log_info "======================================================================"
log_info "Setup complete."
log_info "======================================================================"
log_info " - Automatic APT updates + randomized reboots between 01:00-04:00 ET are enabled."
log_info " - On Proxmox, unattended-upgrades uses permissive Debian/Proxmox patterns that don't crash or silently skip."
log_info " - Daily health checks only email on issues (local disks/ZFS only, and only if pools actually exist)."
log_info " - Weekly maintenance only emails on issues."
log_info " - Boot/reboot events email on real boots/reboots, and all subjects include hostname."
