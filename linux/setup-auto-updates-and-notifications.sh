#!/bin/bash
#
# setup-auto-updates-and-notifications.sh
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
#   - Rule is installed as:
#       /etc/polkit-1/rules.d/00-allow-reboot-all-authenticated.rules
#     (prefixed with 00- to ensure it is evaluated before distro defaults).
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
#   - No “everything is OK” emails are sent.
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
#
# - Credential reuse behavior:
#   - If /etc/msmtprc exists and contains a user:
#       * Show the existing email address.
#       * Prompt whether it should be reused.
#       * Reuse the existing app password when present.
#
# To download and run this script:
# curl -sSL https://gist.githubusercontent.com/chris-shaw-2011/9b78ea951d01c05d41ad7ce5bad4e13e/raw/setup-auto-updates-and-notifications.sh \
#   -o ~/setup-auto-updates-and-notifications.sh && \
#   chmod +x ~/setup-auto-updates-and-notifications.sh && \
#   sudo ~/setup-auto-updates-and-notifications.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

timestamp=$(date +%Y-%m-%dT%H-%M-%S)

backup_if_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    cp "$path" "${path}.${timestamp}.bak"
    echo "Backed up $path → ${path}.${timestamp}.bak"
  fi
}

update_alias() {
  local user=$1
  local email=$2

  if grep -q "^${user}:" /etc/aliases 2>/dev/null; then
    sed -i "s/^${user}:.*/${user}: ${email}/" /etc/aliases
  else
    echo "${user}: ${email}" >> /etc/aliases
  fi
}

is_proxmox() {
  if [ -f /etc/pve/.version ] || dpkg -l | awk '$2=="proxmox-ve" && $1 ~ /^ii/ {found=1} END {exit !found}'; then
    return 0
  else
    return 1
  fi
}

ensure_polkit_reboot_rule() {
  # Allow non-sudo "regular" users (uid >= 1000) to reboot via logind without interactive auth.
  # This is important for remote desktop sessions (e.g., XRDP) and SSH where no polkit agent may be available.
  #
  # Rule ordering matters on some distros; prefix with 00- so it evaluates before default rules.
  local rule_path="/etc/polkit-1/rules.d/00-allow-reboot-all-authenticated.rules"
  local tmp="$(mktemp)"

  # Skip if polkit isn't installed or rules directory doesn't exist.
  if [ ! -d /etc/polkit-1/rules.d ]; then
    return 0
  fi

  cat > "$tmp" <<'EOF'
polkit.addRule(function(action, subject) {
    // Allow reboot for regular (non-system) users (UIDs >= 1000).
    // Works for remote sessions (SSH/XRDP) without requiring interactive auth agents.
    if (subject.uid < 1000) {
        return;
    }

    if (action.id == "org.freedesktop.login1.reboot" ||
        action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
        action.id == "org.freedesktop.login1.reboot-ignore-inhibit" ||
        action.id == "org.freedesktop.login1.reboot-multiple-sessions-ignore-inhibit") {
        return polkit.Result.YES;
    }
});
EOF

  # If file exists and is identical, do nothing.
  if [ -f "$rule_path" ] && cmp -s "$tmp" "$rule_path"; then
    rm -f "$tmp"
    return 0
  fi

  backup_if_exists "$rule_path"
  install -o root -g root -m 0644 "$tmp" "$rule_path"
  rm -f "$tmp"

  # Reload polkit so the rule takes effect immediately.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart polkit 2>/dev/null || true
  fi
}

ensure_polkit_reboot_rule

# Read existing msmtp config so we can offer reuse of email/password
EXISTING_GMAIL_USER=""
EXISTING_GMAIL_APP_PASSWORD=""
if [ -f /etc/msmtprc ]; then
  EXISTING_GMAIL_USER=$(sed -n 's/^user[[:space:]]\+//p' /etc/msmtprc | head -n1 || true)
  EXISTING_GMAIL_APP_PASSWORD=$(sed -n 's/^password[[:space:]]\+//p' /etc/msmtprc | head -n1 || true)
fi

GMAIL_USER=""
GMAIL_APP_PASSWORD=""

if [ -n "$EXISTING_GMAIL_USER" ]; then
  echo "Found existing Gmail address in /etc/msmtprc: $EXISTING_GMAIL_USER"
  read -r -p "Use this email address? [Y/n]: " USE_EXISTING
  USE_EXISTING=${USE_EXISTING:-Y}
  case "$USE_EXISTING" in
    [Yy]*)
      GMAIL_USER="$EXISTING_GMAIL_USER"
      if [ -n "$EXISTING_GMAIL_APP_PASSWORD" ]; then
        echo "Reusing existing Gmail app password from /etc/msmtprc."
        GMAIL_APP_PASSWORD="$EXISTING_GMAIL_APP_PASSWORD"
      else
        read -r -p "Existing config has no password. Enter your Gmail address to confirm: " GMAIL_USER
        read -s -p "Enter your Gmail App Password: " GMAIL_APP_PASSWORD
        echo ""
      fi
      ;;
    *)
      read -r -p "Enter your Gmail address: " GMAIL_USER
      read -s -p "Enter your Gmail App Password: " GMAIL_APP_PASSWORD
      echo ""
      ;;
  esac
else
  read -r -p "Enter your Gmail address: " GMAIL_USER
  read -s -p "Enter your Gmail App Password: " GMAIL_APP_PASSWORD
  echo ""
fi

TO_EMAIL="$GMAIL_USER"

# Ensure timezone is America/New_York so all timers and email timestamps use Eastern
if command -v timedatectl >/dev/null 2>&1; then
  echo "Setting system timezone to America/New_York..."
  timedatectl set-timezone America/New_York || echo "Failed to set timezone via timedatectl."
else
  echo "timedatectl not found; skipping timezone configuration."
fi

# Choose a random reboot time between 01:00 and 03:59 (America/New_York)
# 1:00 = 60 minutes after midnight; range length = 180 minutes (3 hours)
rand_minutes=$((RANDOM % 180))  # 0–179
total_minutes=$((60 + rand_minutes))  # 60–239
reboot_hour=$((total_minutes / 60))    # 1–3
reboot_minute=$((total_minutes % 60))  # 0–59
printf -v REBOOT_TIME "%02d:%02d" "$reboot_hour" "$reboot_minute"
echo "Automatic reboot window randomized; this host will reboot when needed at approximately $REBOOT_TIME America/New_York."

IS_PROXMOX=0
if is_proxmox; then
  IS_PROXMOX=1
  echo "Detected Proxmox VE environment."
else
  echo "Detected generic Debian/Ubuntu environment."
fi

# For non-Proxmox, detect APT origins (for logging + dynamic config)
APT_ORIGINS=()
if [ "$IS_PROXMOX" -eq 0 ]; then
  echo "Detecting APT origins..."
  mapfile -t APT_ORIGINS < <(apt-cache policy | awk '/release / {
    line = $0
    sub(/.*release /, "", line)
    n = split(line, fields, ",")
    o=""; a=""; l=""
    for (i=1; i<=n; i++) {
      f = fields[i]
      gsub(/^ +| +$/, "", f)
      if (f ~ /^o=/) o = substr(f,3)
      else if (f ~ /^a=/) a = substr(f,3)
      else if (f ~ /^l=/) l = substr(f,3)
    }
    if (o && a && l) {
      print "origin=" o ",codename=" a ",label=" l
    }
  }' | sort -u)

  if [[ ${#APT_ORIGINS[@]} -eq 0 ]]; then
    echo "No APT origins detected."
  else
    echo "Detected APT origins:"
    printf ' - %s\n' "${APT_ORIGINS[@]}"
  fi
fi

echo "Installing required packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y msmtp msmtp-mta mailutils unattended-upgrades smartmontools

echo "Writing /etc/msmtprc..."
backup_if_exists /etc/msmtprc
cat > /etc/msmtprc <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
account gmail
host smtp.gmail.com
port 587
from $GMAIL_USER
user $GMAIL_USER
password $GMAIL_APP_PASSWORD

account default : gmail
EOF

chmod 644 /etc/msmtprc
chown root:root /etc/msmtprc

echo "Writing unattended-upgrades configuration..."
backup_if_exists /etc/apt/apt.conf.d/50unattended-upgrades

if [ "$IS_PROXMOX" -eq 1 ]; then
  # Proxmox: use permissive patterns with valid "key=value" entries
  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
        // Any Debian repo (stable/bookworm, security, updates, backports)
        "origin=Debian";
        "o=Debian";

        // Any Proxmox repo (no-subscription, enterprise, etc.)
        "origin=Proxmox";
        "o=Proxmox";
        "site=download.proxmox.com";
};

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Mail "$TO_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::SyslogEnable "true";
EOF
else
  # Generic Debian/Ubuntu: use detected origins (fallback to broad patterns if empty)
  if [[ ${#APT_ORIGINS[@]} -eq 0 ]]; then
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian";
        "origin=Ubuntu";
};

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Mail "$TO_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::SyslogEnable "true";
EOF
  else
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
$(printf '        "%s";\n' "${APT_ORIGINS[@]}")
};

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Mail "$TO_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::SyslogEnable "true";
EOF
  fi
fi

backup_if_exists /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "Enabling unattended-upgrades services/timers (where present)..."
if systemctl list-unit-files | grep -q '^unattended-upgrades.service'; then
  systemctl enable --now unattended-upgrades.service
fi

if systemctl list-unit-files | grep -q '^apt-daily.timer'; then
  systemctl enable --now apt-daily.timer || true
fi
if systemctl list-unit-files | grep -q '^apt-daily-upgrade.timer'; then
  systemctl enable --now apt-daily-upgrade.timer || true
fi

apt update

echo "Writing notification scripts (boot/reboot)..."
backup_if_exists /usr/local/bin/notify-after-boot.sh
cat > /usr/local/bin/notify-after-boot.sh <<EOF
#!/bin/bash
HOSTNAME=\$(hostname)
NOW=\$(date)
UPTIME=\$(uptime -s)
SUBJECT="BOOTED: \${HOSTNAME}"
BODY="The server \${HOSTNAME} has BOOTED UP at \${NOW}.\nUptime started at: \${UPTIME}."
TO="$TO_EMAIL"
while true; do
  echo -e "\${BODY}" | mail -s "\${SUBJECT}" "\$TO" && break
  echo "[\$(date)] Mail send failed, retrying in 5s..."
  sleep 5
done
EOF

backup_if_exists /usr/local/bin/notify-before-reboot.sh
cat > /usr/local/bin/notify-before-reboot.sh <<EOF
#!/bin/bash
HOSTNAME=\$(hostname)
NOW=\$(date)
UPTIME=\$(uptime -p)
SUBJECT="REBOOTING: \${HOSTNAME}"
BODY="The server \${HOSTNAME} is about to REBOOT or SHUT DOWN at \${NOW}.\nIt has been \${UPTIME}."
TO="$TO_EMAIL"
echo -e "\${BODY}" | mail -s "\${SUBJECT}" "\$TO"
EOF

chmod +x /usr/local/bin/notify-*.sh

echo "Writing systemd service units (boot/reboot)..."
backup_if_exists /etc/systemd/system/notify-after-boot.service
cat > /etc/systemd/system/notify-after-boot.service <<EOF
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

backup_if_exists /etc/systemd/system/notify-before-reboot.service
cat > /etc/systemd/system/notify-before-reboot.service <<EOF
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

echo "Writing DAILY health check script..."
backup_if_exists /usr/local/bin/daily-health-check.sh
cat > /usr/local/bin/daily-health-check.sh <<'EOF'
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

sed -i "s|__TO_EMAIL__|$TO_EMAIL|g" /usr/local/bin/daily-health-check.sh
chmod +x /usr/local/bin/daily-health-check.sh

echo "Writing WEEKLY maintenance script..."
backup_if_exists /usr/local/bin/weekly-maintenance.sh
cat > /usr/local/bin/weekly-maintenance.sh <<'EOF'
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
  DEVICES=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
  for d in $DEVICES; do
    OUT=$(smartctl -H "$d" 2>&1 || true)

    if echo "$OUT" | grep -q "SMART support is: Unavailable"; then
      continue
    fi

    if ! echo "$OUT" | grep -q "overall-health self-assessment test result: PASSED"; then
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

sed -i "s|__TO_EMAIL__|$TO_EMAIL|g" /usr/local/bin/weekly-maintenance.sh
chmod +x /usr/local/bin/weekly-maintenance.sh

echo "Writing systemd units for DAILY health check..."
backup_if_exists /etc/systemd/system/daily-health-check.service
cat > /etc/systemd/system/daily-health-check.service <<EOF
[Unit]
Description=Daily health check email (only on issues)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-health-check.sh
EOF

backup_if_exists /etc/systemd/system/daily-health-check.timer
cat > /etc/systemd/system/daily-health-check.timer <<EOF
[Unit]
Description=Run daily health check (only email on issues)

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Writing systemd units for WEEKLY maintenance..."
backup_if_exists /etc/systemd/system/weekly-maintenance.service
cat > /etc/systemd/system/weekly-maintenance.service <<EOF
[Unit]
Description=Weekly maintenance email (only on issues)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/weekly-maintenance.sh
EOF

backup_if_exists /etc/systemd/system/weekly-maintenance.timer
cat > /etc/systemd/system/weekly-maintenance.timer <<EOF
[Unit]
Description=Run weekly maintenance (only email on issues)

[Timer]
OnCalendar=Sun *-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Enabling boot/reboot notifications + health/maintenance timers..."
systemctl daemon-reexec
systemctl daemon-reload
# Do NOT use --now here to avoid fake reboot/boot emails on install
systemctl enable notify-after-boot.service
systemctl enable notify-before-reboot.service
# Timers can start immediately
systemctl enable --now daily-health-check.timer
systemctl enable --now weekly-maintenance.timer

echo "Updating /etc/aliases for all local users (uid >= 1000)..."
getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" { print $1 }' | while read -r user; do
  update_alias "$user" "$TO_EMAIL"
done
update_alias root "$TO_EMAIL"

if command -v newaliases >/dev/null 2>&1; then
  newaliases || echo "newaliases failed (non-fatal)"
else
  echo "Skipping newaliases (not installed)"
fi

echo "Configuring cron to use msmtp for mail delivery..."
CRON_DEFAULT_FILE="/etc/msmtprc"
if [ ! -f "$CRON_DEFAULT_FILE" ]; then
  echo "msmtp config file not found at $CRON_DEFAULT_FILE. Make sure msmtp is installed and configured."
  exit 1
fi

ln -sf "$CRON_DEFAULT_FILE" /etc/mail.rc
ln -sf /usr/bin/msmtp /usr/sbin/sendmail
ln -sf /usr/bin/msmtp /usr/lib/sendmail

backup_if_exists "/etc/crontab"
if grep -q '^MAILTO=' /etc/crontab; then
  sed -i "s/^MAILTO=.*/MAILTO=\"$TO_EMAIL\"/" /etc/crontab
else
  echo "MAILTO=\"$TO_EMAIL\"" >> /etc/crontab
fi

echo "Setup complete."
echo " - Automatic APT updates + randomized reboots between 01:00–04:00 ET are enabled."
echo " - On Proxmox, unattended-upgrades uses permissive Debian/Proxmox patterns that don’t crash or silently skip."
echo " - Daily health checks only email on issues (local disks/ZFS only, and only if pools actually exist)."
echo " - Weekly maintenance only emails on issues."
echo " - Boot/reboot events email on real boots/reboots, and all subjects include hostname."
