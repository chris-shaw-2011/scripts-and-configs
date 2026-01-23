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
#   git clone https://github.com/chris-shaw-2011/scripts-and-configs.git \ 
#   cd scripts-and-configs/linux \
#   sudo ./setup.sh \

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load shared helpers and require root (forward args to common.sh)
. "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"

# If this is a git working tree and clean, pull latest changes (fast-forward only)
if [ "${SETUP_RESTARTED:-0}" = "1" ]; then
	log_debug "SETUP_RESTARTED=1; skipping automatic repo update to avoid restart loop"
else
	if ! command -v git >/dev/null 2>&1; then
		log_warn "git not available; skipping automatic repo update for $SCRIPT_DIR"
	else
		if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			log_warn "$SCRIPT_DIR is not a git working tree; skipping automatic repo update"
		else
			if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]; then
				log_warn "Uncommitted changes in $SCRIPT_DIR; skipping git pull to avoid conflicts"
			else
				log_info "Repository is clean — pulling latest changes for $SCRIPT_DIR"
				OLD_HEAD=$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)
				if git -C "$SCRIPT_DIR" pull --ff-only; then
					NEW_HEAD=$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)
					if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
						log_info "Repository updated (HEAD changed). Restarting setup script to apply updates..."
						exec env SETUP_RESTARTED=1 "$SCRIPT_DIR/$SCRIPT_NAME" "$@"
					else
						log_info "Repository up-to-date; no restart needed"
					fi
				else
					log_warn "git pull failed or would require merge; keeping current files"
				fi
			fi
		fi
	fi
fi

log_info "======================================================================"
log_info "Linux Desktop/Server Setup Script"
log_info "======================================================================"
log_info ""

# Run sub-scripts in order
log_info "Step 1: Setting up polkit reboot rule..."
"$SCRIPT_DIR/polkit-reboot.sh" "$@"
log_info ""

log_info "Step 2: Setting system timezone..."
"$SCRIPT_DIR/timezone-set.sh" "$@"
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
