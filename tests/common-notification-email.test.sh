#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMMON="$REPO_DIR/linux/common.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log_info() {
  echo "$@"
}

log_warn() {
  echo "$@" >&2
}

log_debug() {
  :
}

eval "$(
  sed -n '/^get_notification_email()/,/^}/p' "$COMMON" \
    | sed "s|/etc/msmtprc|$TMP_DIR/msmtprc|g"
)"

stdout=$(printf '%s\n' 'admin@example.com' | get_notification_email)

if [ "$stdout" != "admin@example.com" ]; then
  echo "Expected get_notification_email stdout to contain only the email address" >&2
  printf 'Actual stdout:\n%s\n' "$stdout" >&2
  exit 1
fi
