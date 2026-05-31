#!/bin/bash
#
# msmtp-gmail.sh
#
# Configures msmtp for Gmail-based email notifications.
# Sets timezone to America/New_York and configures mail aliases.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers (pass calling script and forward args)
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

ensure_packages_installed msmtp msmtp-mta mailutils

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
  chmod 644 /etc/msmtprc
  chown root:root /etc/msmtprc
  CHANGED=1
fi

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

log_debug "Ensuring symlinks for msmtp mail delivery are present..."

ensure_symlink /etc/msmtprc /etc/mail.rc || CHANGED=1
ensure_symlink /usr/bin/msmtp /usr/sbin/sendmail || CHANGED=1
ensure_symlink /usr/bin/msmtp /usr/lib/sendmail || CHANGED=1

log_debug "Preparing /etc/crontab MAILTO update..."
CRONTAB_PATH=/etc/crontab
if [ -f "$CRONTAB_PATH" ]; then
  CURRENT_CRONTAB=$(cat "$CRONTAB_PATH")
else
  CURRENT_CRONTAB=""
fi

if echo "$CURRENT_CRONTAB" | grep -q '^MAILTO='; then
  NEW_CRONTAB=$(echo "$CURRENT_CRONTAB" | sed "s/^MAILTO=.*/MAILTO=\"$TO_EMAIL\"/")
else
  # Prepend MAILTO to existing crontab
  if [ -n "$CURRENT_CRONTAB" ]; then
    printf -v NEW_CRONTAB 'MAILTO="%s"\n%s' "$TO_EMAIL" "$CURRENT_CRONTAB"
  else
    printf -v NEW_CRONTAB 'MAILTO="%s"\n' "$TO_EMAIL"
  fi
fi

write_file_if_changed "$CRONTAB_PATH" "$NEW_CRONTAB" || CHANGED=1

if [ "$CHANGED" -eq 1 ]; then
  log_info "All msmtp configuration changes applied"
else
  log_info "No msmtp configuration changes needed"
fi

log_completed_execution
