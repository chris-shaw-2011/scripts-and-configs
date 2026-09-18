# Linux Setup Scripts

Automated setup and maintenance scripts for Debian/Ubuntu servers and desktops, with built-in email notifications and comprehensive health monitoring.

## Overview

`setup.sh` is a modular orchestrator script that configures a Linux system for automatic updates, email notifications, and health monitoring. It runs a series of component scripts that each handle a specific aspect of system administration.

### Target Environments

- Proxmox VE (9.x)
- Generic Debian / Ubuntu servers and desktops

## Key Features

### Automatic Updates
- Enables unattended APT updates from every configured APT origin
- Uses a broad origin pattern so third-party repositories are covered by the same unattended-upgrades policy
- Allows minor/point Proxmox upgrades (e.g., 9.0 → 9.1), but NOT major OS jumps
- Automatically reboots when required at a random time in America/New_York: 01:00–01:30 for Proxmox VE hosts, 01:45–03:59 for KVM/QEMU guests, and 01:00–03:59 for other systems (all endpoints inclusive)
- Detects Proxmox VE hosts from local installation information and assumes all detected KVM/QEMU guests are hosted by Proxmox in this environment
- Reuses an existing valid reboot time on rerun; chooses a new time if it falls outside the detected machine's window

### Authorization & Reboot
- Installs or updates a polkit rule that allows all regular users (UID ≥ 1000) to reboot the system via systemd/logind WITHOUT sudo
- Required for remote sessions (SSH, XRDP) where no interactive polkit authentication agent may be present

### Active Directory Login

- Optionally joins Ubuntu 24.04, Ubuntu 26.04, or Debian 13 (including Debian 13-based Proxmox VE and Backup Server hosts) to one Active Directory domain using `realmd`, `adcli`, and SSSD
- Restricts Linux host login to one selected AD group
- Uses fully qualified names such as `user@example.com`
- Creates home directories on first PAM login and grants the selected group password-protected sudo
- Integrates with existing SSH, terminal, GDM, and XRDP PAM services without installing or reconfiguring those login services
- Validates DNS discovery, clock synchronization, hostname, SSSD, NSS, PAM account access, and sudo policy

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

**Note:** No "everything is OK" emails are sent. When health issues exist, the
latest daily and weekly issue reports are also shown on SSH/login shells and
interactive Bash terminals.

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
2. **timezone-set.sh** — Sets system timezone to America/New_York
3. **active-directory.sh** — Optionally joins Active Directory and configures domain login
4. **msmtp-gmail.sh** — Configures msmtp for Gmail-based email notifications
5. **apt-auto-updates.sh** — Configures unattended-upgrades and automatic update timers
6. **boot-notifications.sh** — Sets up boot and reboot notification scripts + systemd units
7. **health-checks.sh** — Configures daily and weekly health check timers

## Running Individual Scripts

Each sub-script can be run independently:

```bash
sudo ./polkit-reboot.sh
sudo ./timezone-set.sh
sudo ./active-directory.sh
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

### Active Directory Setup

The AD step is optional. On a host with no configured realm, the script asks whether to join and defaults to no. If selected, it prompts for:

- The AD DNS domain
- The join account (default: `Administrator`)
- An optional computer OU distinguished name
- The AD group allowed to log in
- A representative user in that group for validation

The join password is requested directly by `realm` and is not stored or logged. Short group and user names are qualified with the selected domain automatically.

Before a new enrollment, the script installs and verifies dependencies through APT, including `packagekit`, then sets `[service] automatic-install = no` in `/etc/realmd.conf`, starts PackageKit, and restarts realmd. The setting disables automatic installation, but realmd still requires PackageKit to check installed dependencies. Existing realmd settings are preserved and changed files receive timestamped backups; an already joined host skips this enrollment-only preparation.

Before running the join:

- Configure the host to use AD-integrated DNS.
- Ensure `timedatectl show --property=NTPSynchronized --value` reports `yes`.
- Ensure `hostname -f` returns the permanent FQDN beneath the AD domain and the short hostname is no more than 15 characters.
- Do not rename a Proxmox node after cluster creation. Proxmox nodes must have their final hostname before joining a cluster.
- Compatibility is determined from `/etc/os-release`, not Proxmox product versions or installed server packages. Older and future Debian releases are rejected. Establish the permanent PBS FQDN before joining; the script does not rename it or alter certificates and backup integrations.

The script does not change DNS, NTP, hostname, OpenSSH, GNOME, XFCE, XRDP, or the Proxmox VE/PBS web UI authentication realms or backup configuration. Existing login services must already be installed. SSH continues to use its current password/key policy; warnings are printed if its effective configuration may prevent domain login.

After a successful run, keep the current administrator session open and test from a second session:

```bash
ssh -l 'user@example.com' host.example.com
```

- For a terminal login, enter `user@example.com`.
- In GDM, select **Not listed?** for the first domain login.
- In XRDP, enter `user@example.com`; the existing XFCE session configuration is unchanged.
- Confirm that `/home/user@example.com` is created and that `sudo -v` accepts the domain user's password.
- Repeat acceptance on Ubuntu 24.04, Ubuntu 26.04, and Debian 13, including Proxmox VE 9.2 and PBS 4.x. On headless hosts, test SSH and console login; graphical/RDP checks apply only if those services are installed. Domain Linux login does not provision a PBS web UI user or permissions.

After all setup and validation steps pass, the script writes a root-owned completion marker at `/var/lib/active-directory-setup/completed`. Later runs skip the component immediately: no prompts, discovery, verification, policy changes, or SSSD restart. Hosts configured by an older script need one successful run of this version to record completion. The marker records setup success, not ongoing domain health; later configuration changes are not detected automatically.

Without a completion marker, a single compatible SSSD AD membership is reused without requesting join credentials, allowing partial setups to finish. An incompatible realm, multiple configured realms, or a non-SSSD join causes the script to stop instead of replacing authentication configuration. Declined or failed setups do not create a marker.

To deliberately rerun configuration and verification after a completed setup, remove only the marker, then run the component again:

```bash
sudo rm -f /var/lib/active-directory-setup/completed
sudo ./active-directory.sh
```

Removing the marker does not leave or rejoin the domain.

On distributions that enable systemd-activated SSSD responders, `realm join` may also generate a conflicting `services = nss, pam` directive. The script removes that directive only when it contains the standard realm responders, preserves customized responder lists, and disables the duplicate `sssd-pac.socket` while retaining the AD provider's implicit PAC responder. This prevents responder units from leaving systemd in a degraded state even though domain login works.

For SSSD 2.10 or newer, the same cleanup removes realmd's obsolete `[sssd] config_file_version` option. Older SSSD versions retain it. Both changes are validated together and backed up before replacing the configuration. If enrollment already succeeded, rerun the updated script to finish configuration without leaving or rejoining the domain.

Failed-state resets apply only to units present on the host. Newer SSSD releases omit `sssd-pam-priv.socket`; its absence is expected, not an authentication failure.

Managed files are:

- `/etc/sssd/conf.d/90-domain-login.conf`
- `/etc/sudoers.d/80-ad-domain-admins`
- `/etc/realmd.conf` — disables automatic package installation for new enrollment
- `/var/lib/active-directory-setup/completed` — records successful setup and skips future runs

The implementation details and accepted decisions are recorded in [`docs/active-directory-domain-join-plan.md`](docs/active-directory-domain-join-plan.md).

### Customization

Each sub-script can be edited to customize behavior. Key files:

- `/etc/msmtprc` — msmtp configuration
- `/etc/systemd/system/` — Unit files for timers and services
- `/etc/apt/apt.conf.d/` — APT and unattended-upgrades configuration
- `/var/lib/local-health-checks/` — Saved health issue reports shown at terminal startup

## Undo / Rollback

The scripts are designed to be safe to re-run, but they do install system files and enable systemd units. Before overwriting an existing file, helpers create timestamped backups next to the original file using the pattern `<path>.YYYY-MM-DDTHH-MM-SS.bak`.

To roll back a changed config file, find the backup you want and copy it over the active file:

```bash
sudo ls -1 /etc/msmtprc.*.bak /etc/crontab.*.bak /etc/apt/apt.conf.d/*.bak /etc/systemd/system/*.bak 2>/dev/null
sudo cp /path/to/selected.backup.bak /path/to/original-file
```

To disable installed timers and services:

```bash
sudo systemctl disable --now daily-health-check.timer weekly-maintenance.timer
sudo systemctl disable notify-after-boot.service notify-before-reboot.service
sudo systemctl daemon-reload
```

To remove files installed by the notification and health-check scripts:

```bash
sudo rm -f /usr/local/bin/notify-after-boot.sh /usr/local/bin/notify-before-reboot.sh
sudo rm -f /usr/local/bin/daily-health-check.sh /usr/local/bin/weekly-maintenance.sh
sudo rm -rf /var/lib/local-health-checks
sudo rm -f /etc/profile.d/local-health-check-alert.sh
sudo sed -i '/# BEGIN local health check terminal alert/,/# END local health check terminal alert/d' /etc/bash.bashrc
sudo rm -f /etc/systemd/system/notify-after-boot.service /etc/systemd/system/notify-before-reboot.service
sudo rm -f /etc/systemd/system/daily-health-check.service /etc/systemd/system/daily-health-check.timer
sudo rm -f /etc/systemd/system/weekly-maintenance.service /etc/systemd/system/weekly-maintenance.timer
sudo systemctl daemon-reload
```

To undo the polkit reboot rule:

```bash
sudo rm -f /etc/polkit-1/rules.d/00-allow-reboot-all-authenticated.rules
sudo systemctl restart polkit
```

To remove the host's Active Directory integration, first keep a working local root/administrator session open. Remove the computer from the domain with an authorized account, then remove the managed local policy:

```bash
sudo realm leave --user='Administrator' example.com
sudo rm -f /etc/sssd/conf.d/90-domain-login.conf
sudo rm -f /etc/sudoers.d/80-ad-domain-admins
sudo rm -f /var/lib/active-directory-setup/completed
sudo pam-auth-update --disable mkhomedir
sudo systemctl restart sssd
```

Only disable `mkhomedir` if no other network authentication setup needs it. The join script creates timestamped backups of pre-existing SSSD, Kerberos, NSS, and the five active common PAM files, excluding earlier backups; restore those selectively if the machine had earlier custom authentication. After removing the AD provider, restore the package's PAC socket default with `sudo systemctl enable sssd-pac.socket` if SSSD remains installed. If enrollment succeeds but later validation fails, the script deliberately leaves the computer joined—correct the reported issue and rerun it, or use `realm leave` explicitly.

To undo the realmd package-management setting, restore the selected `/etc/realmd.conf.*.bak`, or remove only `automatic-install = no` from its `[service]` section if the script created it. Preserve other settings, then run `sudo systemctl restart realmd`.

To stop unattended upgrades from this setup, disable the timers and restore or remove the apt config files:

```bash
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
```

## Troubleshooting

- **git pull fails**: If your working directory has uncommitted changes, the auto-pull is skipped. Commit or stash your changes and re-run.
- **Email not working**: Verify Gmail SMTP credentials in `/etc/msmtprc` and test with `echo "test" | msmtp your-email@gmail.com`
- **Services not starting**: Check systemd status with `systemctl status <service-name>` and view logs with `journalctl -u <service-name> -n 50`
- **AD discovery fails**: Confirm the configured resolver can find the domain's LDAP and Kerberos SRV records with `realm discover --verbose example.com`.
- **PackageKit unavailable / installed dependencies reported missing**: Rerun the updated script; it installs and starts PackageKit automatically before new enrollment. `automatic-install = no` alone does not bypass realmd package checks. If PackageKit cannot start, enrollment stops; inspect `systemctl status packagekit` and `journalctl -u packagekit`. See the [Debian realmd source](https://sources.debian.org/src/realmd/0.17.1-3/service/realm-packages.c) and [configuration reference](https://manpages.debian.org/trixie/realmd/realmd.conf.5.en.html).
- **A dependency such as `sudo` was skipped but is not installed**: Rerun the updated script. The shared package helper now checks actual installed status instead of merely the presence of a dpkg record; removed or incomplete packages are passed to APT for installation. Held, fully installed packages are still recognized without changing their hold.
- **AD login is denied**: Check `realm list`, `sssctl config-check`, `sssctl user-checks --action=acct --service=login user@example.com`, and `journalctl -u sssd -n 100`.
- **SSSD responder units fail**: Rerun `active-directory.sh`. It reconciles the standard `realmd` NSS/PAM responder list with systemd socket activation and disables the duplicate PAC socket. Customized responder lists are reported for manual review instead of being overwritten.
- **`config_file_version` is not allowed**: realmd 0.17 generates this option, but [SSSD 2.10 removed it](https://sssd.io/release-notes/sssd-2.10.0.html). Rerun the updated script; it removes only that obsolete option from `[sssd]` on affected versions and still rejects unrelated configuration errors. A successful enrollment remains in place.
- **SSH login is denied**: Run `sshd -T` and review `passwordauthentication`, `usepam`, `allowusers`, and `allowgroups`; the AD script intentionally does not change SSH policy.
- **GDM or XRDP login is unavailable**: Verify the relevant PAM file exists (`/etc/pam.d/gdm-password` or `/etc/pam.d/xrdp-sesman`) and that the desktop/RDP service was configured independently.
