#!/bin/bash
#
# polkit-reboot.sh
#
# Installs a polkit rule allowing all regular users (UID ≥ 1000) to reboot
# without sudo using:
# systemctl reboot -i.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

# Rule ordering matters on some distros; prefix with 00- so it evaluates before default rules.
rule_path="/etc/polkit-1/rules.d/00-allow-reboot-all-authenticated.rules"

# Skip if polkit isn't installed or rules directory doesn't exist.
if [ ! -d /etc/polkit-1/rules.d ]; then
  log_warn "polkit rules directory not found; skipping polkit reboot rule setup."

  log_completed_execution
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

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
  log_info "Polkit reboot rule allowing reboot without sudo already in place, nothing to do."
  log_completed_execution
  exit 0
fi

backup_if_exists "$rule_path"
install -o root -g root -m 0644 "$tmp" "$rule_path"
log_info "Installed polkit reboot rule allowing reboot without sudo to $rule_path"

# Reload polkit so the rule takes effect immediately.
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart polkit 2>/dev/null || log_warn "Failed to restart polkit service."
  log_debug "Reloaded polkit service to apply new rule."
else
  log_warn "systemctl not found; cannot reload polkit service."
fi

log_completed_execution
