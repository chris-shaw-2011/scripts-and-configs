#!/bin/bash
#
# msmtp-gmail.sh
#
# Configures msmtp for Gmail-based email notifications.
# Installs a durable local mail queue in front of msmtp so notifications are not
# lost when Internet access is temporarily unavailable (for example, when a
# Proxmox host is shutting down or starting the pfSense VM that provides its
# Internet gateway).
#
# Delivery behavior:
#   - Every message submitted through the local sendmail interface is first
#     persisted under /var/spool/queued-mail.
#   - An immediate SMTP delivery attempt is made when possible.
#   - Failed messages remain queued indefinitely and are retried every minute.
#   - Queued messages survive reboot/shutdown.
#   - Delivery metadata records the first attempt, successful delivery time,
#     and total attempt count. Plain-text messages also receive this information
#     at the top of the message body.
#   - The sendmail-compatible wrapper returns success once the message is safely
#     queued, so a temporary Internet outage does not cause the originating
#     systemd unit or health check to fail.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers (pass calling script and forward args)
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

ensure_packages_installed msmtp msmtp-mta mailutils util-linux

CHANGED=0

# Read existing msmtp config so we can offer reuse of email/password
EXISTING_GMAIL_USER=$(get_notification_email true)
EXISTING_GMAIL_APP_PASSWORD=""

if [ -f /etc/msmtprc ]; then
  EXISTING_GMAIL_APP_PASSWORD=$(sed -n 's/^password[[:space:]]\+//p' /etc/msmtprc | head -n1 || true)
fi

GMAIL_USER=""
GMAIL_APP_PASSWORD=""

if [ -n "$EXISTING_GMAIL_USER" ]; then
  log_info "Found existing Gmail address in /etc/msmtprc: $EXISTING_GMAIL_USER"
  read -r -p "Use this email address? [Y/n]: " USE_EXISTING
  USE_EXISTING=${USE_EXISTING:-Y}

  case "$USE_EXISTING" in
    [Yy]*)
      GMAIL_USER="$EXISTING_GMAIL_USER"

      if [ -n "$EXISTING_GMAIL_APP_PASSWORD" ]; then
        log_debug "Reusing existing Gmail app password from /etc/msmtprc."
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

log_debug "Preparing /etc/msmtprc content..."
MSMTP_CONF=$(cat <<EOF
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
)

if write_file_if_changed /etc/msmtprc "$MSMTP_CONF"; then
  log_debug "/etc/msmtprc unchanged"
else
  log_info "Wrote /etc/msmtprc"
  CHANGED=1
fi

if [ -f /etc/msmtprc ]; then
  if [ "$(stat -c '%a:%U:%G' /etc/msmtprc 2>/dev/null || true)" != "600:root:root" ]; then
    CHANGED=1
  fi
  chmod 600 /etc/msmtprc
  chown root:root /etc/msmtprc
fi

log_debug "Creating durable local notification queue..."
QUEUE_DIR=/var/spool/queued-mail
if [ ! -d "$QUEUE_DIR" ]; then
  mkdir -p "$QUEUE_DIR"
  CHANGED=1
fi
# Sticky + world-writable allows local mail submissions while preventing users
# from deleting one another's queued files. Individual queue files are mode 600.
chmod 1733 "$QUEUE_DIR"
chown root:root "$QUEUE_DIR"

QUEUED_SENDMAIL=$(cat <<'EOF'
#!/bin/bash
# sendmail-compatible durable notification spooler.
# Deliberately ignores sendmail command-line recipient arguments; queued mail is
# later delivered with msmtp -t, which reads recipients from message headers.
set -u

QUEUE_DIR=/var/spool/queued-mail
PROCESSOR=/usr/local/sbin/process-queued-mail

umask 077

# The queue directory is installed by msmtp-gmail.sh. Try to recreate it if it
# was accidentally removed; failure is fatal because durability is the point.
if [ ! -d "$QUEUE_DIR" ]; then
  mkdir -p "$QUEUE_DIR" 2>/dev/null || exit 75
  chmod 1733 "$QUEUE_DIR" 2>/dev/null || true
fi

ID="$(date +%s)-$$-${RANDOM:-0}"
MESSAGE="$QUEUE_DIR/${ID}.eml"
META="$QUEUE_DIR/${ID}.meta"
TMP_MESSAGE="$QUEUE_DIR/.${ID}.tmp"

# Persist the complete RFC-822 message before attempting network delivery.
if ! cat > "$TMP_MESSAGE"; then
  rm -f "$TMP_MESSAGE"
  exit 75
fi
mv "$TMP_MESSAGE" "$MESSAGE"
chmod 600 "$MESSAGE" 2>/dev/null || true

FIRST_ATTEMPT_EPOCH=$(date +%s)
FIRST_ATTEMPT_TEXT=$(date '+%Y-%m-%d %H:%M:%S %Z')
{
  printf 'FIRST_ATTEMPT_EPOCH=%s\n' "$FIRST_ATTEMPT_EPOCH"
  printf 'FIRST_ATTEMPT_TEXT=%s\n' "$FIRST_ATTEMPT_TEXT"
  printf 'ATTEMPTS=0\n'
} > "$META"
chmod 600 "$META" 2>/dev/null || true

# System notifications normally run as root, so try immediately. If this is a
# non-root submission, the root-owned systemd retry service will pick it up.
if [ "$(id -u)" -eq 0 ] && [ -x "$PROCESSOR" ]; then
  "$PROCESSOR" --one "$ID" >/dev/null 2>&1 || true
fi

# Once safely queued, report success to the caller. Network failure is handled
# asynchronously and must not make boot/reboot/health systemd units fail.
exit 0
EOF
)

PROCESS_QUEUED_MAIL=$(cat <<'EOF'
#!/bin/bash
# Processes durable local notification mail. Failed messages remain queued and
# are retried by queued-mail-delivery.timer until SMTP delivery succeeds.
set -u

QUEUE_DIR=/var/spool/queued-mail
LOCK_FILE=/run/queued-mail-delivery.lock
MSMTP=/usr/bin/msmtp

mkdir -p "$QUEUE_DIR"
chmod 1733 "$QUEUE_DIR" 2>/dev/null || true

# Prevent the immediate sender and timer from processing the same message at once.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

process_message() {
  local id="$1"
  local message="$QUEUE_DIR/${id}.eml"
  local meta="$QUEUE_DIR/${id}.meta"
  local delivery="$QUEUE_DIR/.${id}.delivery"
  local new_meta="$QUEUE_DIR/.${id}.meta.new"
  local first_text=""
  local first_epoch=""
  local attempts="0"
  local delivered_text=""
  local is_complex="0"

  [ -f "$message" ] || return 0

  if [ -f "$meta" ]; then
    first_epoch=$(sed -n 's/^FIRST_ATTEMPT_EPOCH=//p' "$meta" | head -n1)
    first_text=$(sed -n 's/^FIRST_ATTEMPT_TEXT=//p' "$meta" | head -n1)
    attempts=$(sed -n 's/^ATTEMPTS=//p' "$meta" | head -n1)
  fi

  case "$attempts" in
    ''|*[!0-9]*) attempts=0 ;;
  esac

  if [ -z "$first_epoch" ]; then
    first_epoch=$(date +%s)
  fi
  if [ -z "$first_text" ]; then
    first_text=$(date '+%Y-%m-%d %H:%M:%S %Z')
  fi

  attempts=$((attempts + 1))
  delivered_text=$(date '+%Y-%m-%d %H:%M:%S %Z')

  {
    printf 'FIRST_ATTEMPT_EPOCH=%s\n' "$first_epoch"
    printf 'FIRST_ATTEMPT_TEXT=%s\n' "$first_text"
    printf 'ATTEMPTS=%s\n' "$attempts"
  } > "$new_meta"
  mv "$new_meta" "$meta"
  chmod 600 "$meta" 2>/dev/null || true

  # Multipart/HTML mail may not render a plain-text preamble predictably, so it
  # receives delivery metadata as headers only. Normal system text mail also
  # receives a visible block at the top of the body.
  if grep -Eiq '^Content-Type:[[:space:]]*(multipart/|text/html)' "$message"; then
    is_complex=1
  fi

  awk \
    -v first="$first_text" \
    -v attempts="$attempts" \
    -v delivered="$delivered_text" \
    -v complex="$is_complex" '
      BEGIN { in_headers=1 }
      in_headers && /^\r?$/ {
        print "X-Notification-First-Attempt: " first
        print "X-Notification-Delivery-Attempts: " attempts
        print "X-Notification-Delivered-At: " delivered
        print
        if (complex == 0) {
          print "=== Notification delivery ==="
          print "First delivery attempt: " first
          print "Delivery attempts: " attempts
          print "Delivered: " delivered
          print ""
        }
        in_headers=0
        next
      }
      { print }
    ' "$message" > "$delivery"

  chmod 600 "$delivery" 2>/dev/null || true

  if "$MSMTP" -t < "$delivery"; then
    rm -f "$message" "$meta" "$delivery"
    logger -t queued-mail "Delivered queued notification ${id} after ${attempts} attempt(s); first attempt ${first_text}"
    return 0
  fi

  rm -f "$delivery"
  logger -t queued-mail "Delivery attempt ${attempts} failed for queued notification ${id}; first attempt ${first_text}; will retry"
  return 1
}

if [ "${1:-}" = "--one" ] && [ -n "${2:-}" ]; then
  process_message "$2" || true
  exit 0
fi

for message in "$QUEUE_DIR"/*.eml; do
  [ -f "$message" ] || continue
  id=$(basename "$message" .eml)
  process_message "$id" || true
done

exit 0
EOF
)

QUEUE_SERVICE=$(cat <<'EOF'
[Unit]
Description=Retry queued system notification emails
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/process-queued-mail
EOF
)

QUEUE_TIMER=$(cat <<'EOF'
[Unit]
Description=Retry queued system notification emails every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
)

if write_file_if_changed /usr/local/sbin/queued-sendmail "$QUEUED_SENDMAIL"; then
  :
else
  chmod 755 /usr/local/sbin/queued-sendmail
  CHANGED=1
fi

if write_file_if_changed /usr/local/sbin/process-queued-mail "$PROCESS_QUEUED_MAIL"; then
  :
else
  chmod 755 /usr/local/sbin/process-queued-mail
  CHANGED=1
fi

write_file_if_changed /etc/systemd/system/queued-mail-delivery.service "$QUEUE_SERVICE" || CHANGED=1
write_file_if_changed /etc/systemd/system/queued-mail-delivery.timer "$QUEUE_TIMER" || CHANGED=1

log_debug "Updating /etc/aliases for all local users (uid >= 1000)..."
while read -r user; do
  update_alias "$user" "$TO_EMAIL" || CHANGED=1
done < <(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" { print $1 }')

update_alias root "$TO_EMAIL" || CHANGED=1

if command -v newaliases >/dev/null 2>&1; then
  newaliases || log_warn "newaliases failed (non-fatal)"
else
  log_warn "newaliases not installed; skipping."
fi

log_debug "Ensuring local sendmail interface points to the durable queue..."
ensure_symlink /etc/msmtprc /etc/mail.rc || CHANGED=1
ensure_symlink /usr/local/sbin/queued-sendmail /usr/sbin/sendmail || CHANGED=1
ensure_symlink /usr/local/sbin/queued-sendmail /usr/lib/sendmail || CHANGED=1

log_debug "Preparing /etc/crontab MAILTO update..."
CRONTAB_PATH=/etc/crontab
if [ -f "$CRONTAB_PATH" ]; then
  CURRENT_CRONTAB=$(cat "$CRONTAB_PATH")
else
  CURRENT_CRONTAB=""
fi

# Repair older runs that wrote literal "\n" text instead of real newlines.
CURRENT_CRONTAB=${CURRENT_CRONTAB//\\n/$'\n'}

if echo "$CURRENT_CRONTAB" | grep -q '^MAILTO='; then
  NEW_CRONTAB=$(echo "$CURRENT_CRONTAB" | sed "s/^MAILTO=.*/MAILTO=\"$TO_EMAIL\"/")
else
  if [ -n "$CURRENT_CRONTAB" ]; then
    printf -v NEW_CRONTAB 'MAILTO="%s"\n%s' "$TO_EMAIL" "$CURRENT_CRONTAB"
  else
    printf -v NEW_CRONTAB 'MAILTO="%s"\n' "$TO_EMAIL"
  fi
fi

write_file_if_changed "$CRONTAB_PATH" "$NEW_CRONTAB" || CHANGED=1

if [ "$CHANGED" -eq 1 ]; then
  log_info "Reloading systemd configuration for queued mail delivery..."
  systemctl daemon-reload
fi

if ! systemctl is-enabled --quiet queued-mail-delivery.timer 2>/dev/null; then
  log_info "Enabling queued-mail-delivery.timer"
  systemctl enable --now queued-mail-delivery.timer
else
  systemctl start queued-mail-delivery.timer >/dev/null 2>&1 || true
  log_debug "queued-mail-delivery.timer already enabled"
fi

# Process anything left from a previous boot/setup immediately. Failure is fine;
# the timer will continue retrying indefinitely.
systemctl start queued-mail-delivery.service >/dev/null 2>&1 || true

if [ "$CHANGED" -eq 1 ]; then
  log_info "All msmtp/queued-mail configuration changes applied"
else
  log_info "No msmtp/queued-mail configuration changes needed"
fi

log_completed_execution
