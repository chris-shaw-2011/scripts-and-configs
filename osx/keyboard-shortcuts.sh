#!/usr/bin/env bash
#
# keyboard-shortcuts.sh
#
# Configures macOS symbolic hotkeys (System Settings -> Keyboard -> Shortcuts)
# that the Karabiner-Elements complex modification rules depend on.
#
# Currently managed:
#   - "Show Launchpad"  -> Cmd+Shift+L   (symbolichotkey id 160)
#       (so that tap-Option in Karabiner can open Launchpad)
#   - "Show Desktop"    -> Cmd+Shift+D   (symbolichotkey id 36)
#       (so that Option+D in Karabiner can show the desktop)
#
# Behavior:
#   - If a shortcut is unset or already matches the desired value, no prompt.
#   - If it's set to a *different* custom value, the script WARNS and skips
#     it by default rather than clobbering your customization.
#
# Flags:
#   --force-shortcuts  Overwrite existing custom bindings with our values.
#   --reset-shortcuts  Delete our managed entries entirely (revert to macOS
#                      default) and exit without applying anything.
#
# Idempotent: re-running with the same desired values is a no-op.
# Backs up ~/Library/Preferences/com.apple.symbolichotkeys.plist before
# making any changes.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# load shared helpers
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

PLIST="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"

# macOS modifier flag bits (NSEvent modifier flags)
readonly MOD_SHIFT=131072    # 1 << 17
readonly MOD_CONTROL=262144  # 1 << 18
readonly MOD_OPTION=524288   # 1 << 19
readonly MOD_COMMAND=1048576 # 1 << 20

FORCE_SHORTCUTS=0
RESET_SHORTCUTS=0
for arg in "$@"; do
  case "$arg" in
    --force-shortcuts) FORCE_SHORTCUTS=1 ;;
    --reset-shortcuts) RESET_SHORTCUTS=1 ;;
  esac
done

# Ensure jq is present (we use it to compare current vs. desired settings)
if ! command -v jq >/dev/null 2>&1; then
  log_warn "jq is not installed; attempting to install via Homebrew..."
  if ! ensure_brew_package jq; then
    log_error "jq is required for idempotent comparison. Install via: brew install jq"
    log_completed_execution
    exit 1
  fi
fi

# Track whether we actually changed anything so we know to restart cfprefsd.
CHANGED=0

# Managed symbolic hotkey ids (used by --reset-shortcuts).
MANAGED_IDS=(160 36)

# Human-readable summary of a (key_char, key_code, modifiers) tuple.
describe_binding() {
  local params_json="$1"

  if [ "$params_json" = "null" ] || [ -z "$params_json" ]; then
    echo "(unset)"
    return
  fi

  local key_char key_code mods
  key_char=$(printf '%s' "$params_json" | jq -r '.[0]')
  key_code=$(printf '%s' "$params_json" | jq -r '.[1]')
  mods=$(printf '%s' "$params_json" | jq -r '.[2]')

  local parts=""
  (( mods & MOD_CONTROL )) && parts="${parts}Ctrl+"
  (( mods & MOD_OPTION ))  && parts="${parts}Opt+"
  (( mods & MOD_SHIFT ))   && parts="${parts}Shift+"
  (( mods & MOD_COMMAND )) && parts="${parts}Cmd+"

  local label
  # key_char == 65535 (0xFFFF) means "no printable char" (function key, arrow, etc.).
  if [ "$key_char" = "65535" ] || ! [ "$key_char" -gt 32 ] 2>/dev/null; then
    case "$key_code" in
      122) label="F1"  ;; 120) label="F2"  ;;  99) label="F3"  ;; 118) label="F4"  ;;
       96) label="F5"  ;;  97) label="F6"  ;;  98) label="F7"  ;; 100) label="F8"  ;;
      101) label="F9"  ;; 109) label="F10" ;; 103) label="F11" ;; 111) label="F12" ;;
      123) label="Left" ;; 124) label="Right" ;; 125) label="Down" ;; 126) label="Up" ;;
      36)  label="Return" ;; 48) label="Tab" ;; 49) label="Space" ;; 53) label="Esc" ;;
      *)   label="keycode=$key_code" ;;
    esac
  else
    label=$(printf '%b' "$(printf '\\x%x' "$key_char")")
  fi
  printf '%s%s (char=%s, code=%s, mods=%s)' "$parts" "$label" "$key_char" "$key_code" "$mods"
}

# Read the current parameters tuple for a symbolichotkey id from the plist.
# Echos a JSON array like "[108,37,1179648]" or "null" if not set.
# Normalizes to numeric elements because macOS sometimes stores these as strings.
read_current_params() {
  local id="$1"

  if [ ! -f "$PLIST" ]; then
    echo "null"
    return 0
  fi

  plutil -convert json -o - "$PLIST" 2>/dev/null \
    | jq -c --arg id "$id" '
        .AppleSymbolicHotKeys[$id].value.parameters // null
        | if type == "array" then map(tonumber) else . end
      ' \
    2>/dev/null || echo "null"
}

# Reset mode: remove our managed entries so macOS falls back to its defaults.
if [ "$RESET_SHORTCUTS" -eq 1 ]; then
  log_info "Resetting managed symbolic hotkeys to macOS defaults..."

  for id in "${MANAGED_IDS[@]}"; do
    current=$(read_current_params "$id")
    if [ "$current" = "null" ]; then
      log_debug "Hotkey $id already unset; skipping"
      continue
    fi

    if [ "$CHANGED" -eq 0 ]; then
      backup_if_exists "$PLIST"
    fi

    if /usr/libexec/PlistBuddy -c "Delete :AppleSymbolicHotKeys:$id" "$PLIST" 2>/dev/null; then
      log_info "Removed managed entry for symbolic hotkey $id (was $(describe_binding "$current"))"
      CHANGED=1
    else
      log_warn "Could not remove entry for symbolic hotkey $id"
    fi
  done

  if [ "$CHANGED" -eq 1 ]; then
    /usr/bin/killall cfprefsd 2>/dev/null || true
    log_info "Done. Log out and back in (or restart) for macOS to fully pick up the reset."
  else
    log_info "Nothing to reset."
  fi
  log_completed_execution
  exit 0
fi

# Set a symbolichotkey to a given (key_char, key_code, modifier_flags).
# - Skips if already at the desired value.
# - Applies if unset.
# - If a *different* custom value is present, warns and skips unless
#   --force-shortcuts was passed.
#
# Usage: set_symbolic_hotkey <id> <key_char> <key_code> <modifiers> <description>
set_symbolic_hotkey() {
  local id="$1"
  local key_char="$2"
  local key_code="$3"
  local modifiers="$4"
  local desc="$5"

  local desired_json
  desired_json=$(printf '[%s,%s,%s]' "$key_char" "$key_code" "$modifiers")

  local current_json
  current_json=$(read_current_params "$id")

  local current_enabled
  if [ -f "$PLIST" ]; then
    current_enabled=$(plutil -convert json -o - "$PLIST" 2>/dev/null \
      | jq -r --arg id "$id" '.AppleSymbolicHotKeys[$id].enabled // false' \
      2>/dev/null || echo "false")
  else
    current_enabled="false"
  fi

  # Normalize: plutil emits booleans as 0/1, jq emits true/false; accept both.
  local enabled_bool="false"
  case "$current_enabled" in
    true|1) enabled_bool="true" ;;
  esac

  if [ "$current_json" = "$desired_json" ] && [ "$enabled_bool" = "true" ]; then
    log_debug "Symbolic hotkey $id ($desc) already set to $(describe_binding "$current_json"); skipping"
    return 0
  fi

  if [ "$current_json" != "null" ]; then
    log_warn "Symbolic hotkey $id ($desc) has a CUSTOM binding."
    log_warn "  Current: $(describe_binding "$current_json") (enabled=$enabled_bool)"
    log_warn "  Desired: $(describe_binding "$desired_json")"
    if [ "$FORCE_SHORTCUTS" -eq 0 ]; then
      log_warn "  Skipping to preserve your customization. Re-run with --force-shortcuts to overwrite,"
      log_warn "  or with --reset-shortcuts to revert to macOS default first."
      log_warn "  NOTE: the Karabiner rule that relies on this shortcut will not work until this is set."
      return 0
    fi
    log_warn "  --force-shortcuts passed; overwriting."
  fi

  if [ "$CHANGED" -eq 0 ]; then
    backup_if_exists "$PLIST"
  fi

  log_info "Configuring symbolic hotkey $id: $desc -> $(describe_binding "$desired_json")"
  /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$id" \
    "{ enabled = 1; value = { parameters = ($key_char, $key_code, $modifiers); type = standard; }; }"

  CHANGED=1
}

CMD_SHIFT=$(( MOD_COMMAND | MOD_SHIFT ))

# Show Launchpad (id 160) -> Cmd+Shift+L
#   key_char = ASCII 'l' = 108
#   key_code = virtual key for 'L' on US layout = 37
set_symbolic_hotkey 160 108 37 "$CMD_SHIFT" "Show Launchpad (Cmd+Shift+L)"

# Show Desktop (id 36) -> Cmd+Shift+D
#   key_char = ASCII 'd' = 100
#   key_code = virtual key for 'D' on US layout = 2
set_symbolic_hotkey 36 100 2 "$CMD_SHIFT" "Show Desktop (Cmd+Shift+D)"

if [ "$CHANGED" -eq 1 ]; then
  log_info "Restarting cfprefsd so the new shortcuts take effect..."
  /usr/bin/killall cfprefsd 2>/dev/null || true

  log_info ""
  log_warn "Note: macOS may require you to log out and back in (or restart) for newly"
  log_warn "configured global shortcuts to be picked up by all running apps."
  log_warn "You can verify the bindings in:"
  log_warn "  System Settings -> Keyboard -> Keyboard Shortcuts -> Launchpad & Dock / Mission Control"
else
  log_info "macOS keyboard shortcuts already configured; nothing to do."
fi

log_completed_execution
