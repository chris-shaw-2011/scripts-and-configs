#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/linux/health-checks.sh"

assert_contains() {
  local haystack=$1
  local needle=$2
  local description=$3

  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected $description" >&2
    echo "Missing: $needle" >&2
    exit 1
  fi
}

daily_script=$(sed -n '/^DAILY_HEALTH_CHECK=$(cat <<'\''EOF'\''/,/^EOF$/p' "$SCRIPT")
weekly_script=$(sed -n '/^WEEKLY_MAINTENANCE=$(cat <<'\''EOF'\''/,/^EOF$/p' "$SCRIPT")
installer=$(cat "$SCRIPT")

assert_contains "$daily_script" 'ALERT_DIR=/var/lib/local-health-checks' "daily health script to configure alert directory"
assert_contains "$daily_script" 'ALERT_FILE="${ALERT_DIR}/daily-issues.txt"' "daily health script to use a daily alert file"
assert_contains "$daily_script" 'printf "%s\n" "$REPORT" > "$ALERT_FILE"' "daily health script to write issue report for terminal display"
assert_contains "$daily_script" 'rm -f "$ALERT_FILE"' "daily health script to clear stale daily alerts"

assert_contains "$weekly_script" 'ALERT_DIR=/var/lib/local-health-checks' "weekly maintenance script to configure alert directory"
assert_contains "$weekly_script" 'ALERT_FILE="${ALERT_DIR}/weekly-issues.txt"' "weekly maintenance script to use a weekly alert file"
assert_contains "$weekly_script" 'printf "%s\n" "$REPORT" > "$ALERT_FILE"' "weekly maintenance script to write issue report for terminal display"
assert_contains "$weekly_script" 'rm -f "$ALERT_FILE"' "weekly maintenance script to clear stale weekly alerts"

assert_contains "$installer" 'HEALTH_ALERT_PROFILE=$(cat <<'\''EOF'\''' "installer to define a profile.d health alert script"
assert_contains "$installer" 'write_file_if_changed /etc/profile.d/local-health-check-alert.sh "$HEALTH_ALERT_PROFILE"' "installer to write the profile.d health alert script"
assert_contains "$installer" 'HEALTH_ALERT_BASHRC_SNIPPET=$(cat <<'\''EOF'\''' "installer to define an interactive bashrc health alert hook"
assert_contains "$installer" '/etc/profile.d/local-health-check-alert.sh' "bashrc hook to source the profile.d health alert script"
