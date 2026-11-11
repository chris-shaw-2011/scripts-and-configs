#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub system commands and initialization so tests never write live preferences.
sed \
  -e 's|/usr/bin/defaults|defaults|g' \
  -e 's|/usr/libexec/PlistBuddy|PlistBuddy|g' \
  -e 's|/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings|activateSettings|g' \
  "$REPO_DIR/osx/keyboard-shortcuts.sh" > "$TMP_DIR/keyboard-shortcuts.sh"

{
  printf '%s\n' 'set -eu -o pipefail' 'DEBUG=1' \
    'COLOR_DEBUG=""' 'COLOR_WARN=""' 'COLOR_ERROR=""' 'COLOR_RESET=""' \
    'CALLING_SCRIPT=osx-keyboard-shortcuts.test.sh'
  for helper in log_info log_warn log_error log_debug log_completed_execution \
    timestamp backup_if_exists; do
    sed -n "/^$helper()/,/^}/p" "$REPO_DIR/osx/common.sh"
  done
  cat <<'EOF'
ensure_brew_package() { return 1; }
plutil() { cat "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"; }
defaults() {
  local plist="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
  case "$1" in
    read)
      jq -er '.fnState // empty' "$HOME/state.json"
      ;;
    write)
      printf '%s\n' "$*" >> "$HOME/calls"
      if [ "$2" = "-g" ]; then
        [ "${FAIL_FN_WRITE:-0}" = 0 ] || return 1
        jq '.fnState = 1' "$HOME/state.json" > "$HOME/next.json"
        mv "$HOME/next.json" "$HOME/state.json"
      else
        local id="$5" value="$6" tuple
        tuple=$(printf '%s' "$value" | sed -n 's/.*parameters = (\([^)]*\)).*/[\1]/p')
        jq --arg id "$id" --argjson tuple "$tuple" \
          '.AppleSymbolicHotKeys[$id] = {enabled: 1, value: {parameters: ($tuple | map(tostring)), type: "standard"}}' \
          "$plist" > "$HOME/next.json"
        mv "$HOME/next.json" "$plist"
      fi
      ;;
    *) return 1 ;;
  esac
}
PlistBuddy() {
  local id="${2##*:}"
  jq --arg id "$id" 'del(.AppleSymbolicHotKeys[$id])' "$3" > "$HOME/next.json"
  mv "$HOME/next.json" "$3"
}
activateSettings() { echo "activate $*" >> "$HOME/calls"; }
EOF
} > "$TMP_DIR/common.sh"

new_case() {
  export HOME="$TMP_DIR/$1"
  mkdir -p "$HOME/Library/Preferences"
  printf '%s\n' '{"AppleSymbolicHotKeys":{"99":{"enabled":true}}}' \
    > "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
  printf '%s\n' '{}' > "$HOME/state.json"
  touch "$HOME/Library/Preferences/.GlobalPreferences.plist" "$HOME/calls"
}

run_setup() {
  bash "$TMP_DIR/keyboard-shortcuts.sh" "$@" > "$HOME/output" 2>&1 \
    || fail "Setup failed: $(cat "$HOME/output")"
}

new_case fresh
run_setup
plist="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
jq -e '.AppleSymbolicHotKeys["31"] |
  .enabled == 1 and (.value.parameters | map(tonumber)) == [115,1,655360]' \
  "$plist" >/dev/null || fail "Screenshot shortcut not enabled as Option+Shift+S"
jq -e '.fnState == 1' "$HOME/state.json" >/dev/null \
  || fail "Missing function-key preference was not enabled"
jq -e '.AppleSymbolicHotKeys["99"].enabled == true' "$plist" >/dev/null \
  || fail "Unmanaged shortcuts changed"
grep -q 'Backed up .*com.apple.symbolichotkeys.plist' "$HOME/output" \
  || fail "Shortcut preferences were not backed up"
grep -q 'Backed up .*\.GlobalPreferences.plist' "$HOME/output" \
  || fail "Function-key preferences were not backed up"
grep -q '^activate -u$' "$HOME/calls" || fail "Settings were not activated"

before=$(cat "$plist")
: > "$HOME/calls"
run_setup
[ "$(cat "$plist")" = "$before" ] || fail "Rerun changed shortcuts"
[ ! -s "$HOME/calls" ] || fail "Rerun wrote or activated unchanged settings"
! grep -q 'Backed up' "$HOME/output" || fail "Rerun created backups"

printf '%s\n' '{"fnState":0}' > "$HOME/state.json"
run_setup
[ "$(cat "$plist")" = "$before" ] || fail "Fn-only change altered shortcuts"
jq -e '.fnState == 1' "$HOME/state.json" >/dev/null \
  || fail "Media-key mode was not replaced with standard function keys"
! grep -q 'Backed up .*com.apple.symbolichotkeys.plist' "$HOME/output" \
  || fail "Fn-only change backed up untouched shortcuts"

jq '.AppleSymbolicHotKeys["31"] = {
  enabled: true, value: {parameters: [36,21,1441792], type: "standard"}}' \
  "$plist" > "$HOME/next.json"
mv "$HOME/next.json" "$plist"
before=$(cat "$plist")
: > "$HOME/calls"
run_setup
[ "$(cat "$plist")" = "$before" ] || fail "Custom screenshot shortcut overwritten"
[ ! -s "$HOME/calls" ] || fail "Preserved custom shortcut caused writes"
run_setup --force-shortcuts
jq -e '(.AppleSymbolicHotKeys["31"].value.parameters | map(tonumber)) == [115,1,655360]' \
  "$plist" >/dev/null || fail "Force did not replace custom screenshot shortcut"

printf '%s\n' '{"fnState":0}' > "$HOME/state.json"
: > "$HOME/calls"
run_setup --reset-shortcuts
jq -e '.AppleSymbolicHotKeys == {"99":{"enabled":true}}' "$plist" >/dev/null \
  || fail "Reset did not remove only managed shortcuts"
jq -e '.fnState == 0' "$HOME/state.json" >/dev/null \
  || fail "Shortcut reset changed function-key mode"
! grep -q 'write -g' "$HOME/calls" || fail "Reset wrote function-key preference"

new_case failure
if FAIL_FN_WRITE=1 bash "$TMP_DIR/keyboard-shortcuts.sh" > "$HOME/output" 2>&1; then
  fail "Function-key write failure was reported as success"
fi
! grep -q '^activate' "$HOME/calls" || fail "Failed setup activated settings"

echo "macOS keyboard shortcut tests passed."
