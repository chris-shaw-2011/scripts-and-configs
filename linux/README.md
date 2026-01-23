# Linux Setup Scripts

Automated setup and maintenance scripts for Debian/Ubuntu servers and desktops, with built-in email notifications and comprehensive health monitoring.

## Overview

`setup.sh` is a modular orchestrator script that configures a Linux system for automatic updates, email notifications, and health monitoring. It runs a series of component scripts that each handle a specific aspect of system administration.

### Target Environments

- Proxmox VE (9.x)
- Generic Debian / Ubuntu servers and desktops

## Key Features

### Automatic Updates
- Enables unattended APT updates for all appropriate origins
- On Proxmox, uses permissive origin patterns so repo metadata changes do not break updates
- Allows minor/point Proxmox upgrades (e.g., 9.0 → 9.1), but NOT major OS jumps
- Automatically reboots when required, within a randomized window between 01:00–04:00 America/New_York (per-host randomization)

### Authorization & Reboot
- Installs or updates a polkit rule that allows all regular users (UID ≥ 1000) to reboot the system via systemd/logind WITHOUT sudo
- Required for remote sessions (SSH, XRDP) where no interactive polkit authentication agent may be present

### Email Notifications via Gmail (msmtp)
- Sends emails on BOOT and before REBOOT/SHUTDOWN
- All subjects include the hostname
- `unattended-upgrades` sends mail only on changes/errors (MailReport=on-change)

#### Daily Health Alerts (only when issues exist)
- Failed systemd units
- Low disk space on local filesystems (network/FUSE excluded)
- ZFS pool health or high usage (only if pools exist)
- Reboot-required flag

#### Weekly Maintenance Alerts (only when issues exist)
- ZFS scrub or pool health problems
- SMART disk health failures
- apt autoremove / clean errors

**Note:** No "everything is OK" emails are sent.

### Storage & Monitoring
- ZFS tools or pools: skipped silently if unavailable
- SMART monitoring: skips devices that don't support SMART
- Timezone: forces system timezone to America/New_York
- All email timestamps use the system timezone

### Design Principles
- Script is idempotent and safe to re-run
- Important config files are backed up with timestamped .bak suffixes
- Prefers systemd services/timers over cron where possible
- Each sub-script is independent and can be run separately
- Automatically pulls latest changes from git repository on each run (if repository is clean)
- Auto-restarts the setup script if repository changes are pulled

## Installation

### Clone the Repository

```bash
git clone https://github.com/chris-shaw-2011/scripts-and-configs.git
cd scripts-and-configs/linux
sudo ./setup.sh
```

## What Gets Installed

The setup script runs the following sub-scripts in order:

1. **polkit-reboot.sh** — Installs polkit rule to allow regular users to reboot without sudo
2. **set-timezone.sh** — Sets system timezone to America/New_York
3. **msmtp-gmail.sh** — Configures msmtp for Gmail-based email notifications
4. **apt-auto-updates.sh** — Configures unattended-upgrades and automatic update timers
5. **boot-notifications.sh** — Sets up boot and reboot notification scripts + systemd units
6. **health-checks.sh** — Configures daily and weekly health check timers

## Running Individual Scripts

Each sub-script can be run independently:

```bash
sudo ./polkit-reboot.sh
sudo ./timezone-set.sh
sudo ./msmtp-gmail.sh
sudo ./apt-auto-updates.sh
sudo ./boot-notifications.sh
sudo ./health-checks.sh
```

## Debug Mode

To see detailed logging output, run with the `--debug` flag:

```bash
sudo ./setup.sh --debug
```

## How It Works

1. **Git Integration**: On each run, `setup.sh` checks if the repository is a git working tree with no uncommitted changes
2. **Auto-Update**: If clean, it performs a fast-forward `git pull` to fetch latest changes
3. **Auto-Restart**: If the pull changes HEAD, the script automatically restarts itself (via `exec`) to apply the updates
4. **Component Execution**: Once git is handled, the script runs all component scripts in sequence
5. **Idempotency**: All scripts check before making changes and only write/enable services/timers when necessary

## Configuration

### Email Setup

When running `msmtp-gmail.sh`, you will be prompted to enter the Gmail account email address for sending notifications. The script will:

- Prompt for email if not already configured
- Set up msmtp configuration with Gmail SMTP settings
- Create a systemd timer for daily health checks
- Create a systemd timer for weekly maintenance checks

### Customization

Each sub-script can be edited to customize behavior. Key files:

- `/etc/msmtprc` — msmtp configuration
- `/etc/systemd/system/` — Unit files for timers and services
- `/etc/apt/apt.conf.d/` — APT and unattended-upgrades configuration

## Troubleshooting

- **git pull fails**: If your working directory has uncommitted changes, the auto-pull is skipped. Commit or stash your changes and re-run.
- **Email not working**: Verify Gmail SMTP credentials in `/etc/msmtprc` and test with `echo "test" | msmtp your-email@gmail.com`
- **Services not starting**: Check systemd status with `systemctl status <service-name>` and view logs with `journalctl -u <service-name> -n 50`
