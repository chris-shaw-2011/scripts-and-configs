#!/usr/bin/env bash
#
# diagnose-tiling.sh
#
# Read-only diagnostic. Prints everything relevant to why Option+Arrow
# tiling might not be working. Does not modify anything.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

echo "==== 1. Is Karabiner-Elements running? ===="
pgrep -lf karabiner_grabber || echo "  karabiner_grabber NOT running"
pgrep -lf karabiner_console_user_server || echo "  karabiner_console_user_server NOT running"
echo

echo "==== 2. Active Karabiner profile ===="
KJ="$HOME/.config/karabiner/karabiner.json"
if [ ! -f "$KJ" ]; then
  echo "  MISSING: $KJ"
else
  jq -r '.profiles[] | select(.selected == true) | "  name: \(.name)"' "$KJ"
fi
echo

echo "==== 3. Tiling rule present + enabled in active profile? ===="
if [ -f "$KJ" ]; then
  jq '.profiles[] | select(.selected == true) | .complex_modifications.rules[]
        | select(.description | test("tiles the focused window"))
        | {description, first_from: .manipulators[0].from, first_to: .manipulators[0].to}' "$KJ" \
    || echo "  rule NOT found in active profile"
fi
echo

echo "==== 4. Any device-level 'Modify events' disabled? ===="
if [ -f "$KJ" ]; then
  jq '.profiles[] | select(.selected == true) | .devices // []
        | map({id: .identifiers, modify_events: (.modify_events // true), ignore: (.ignore // false)})' "$KJ"
fi
echo

echo "==== 5. Rectangle installed & running? ===="
if [ -d /Applications/Rectangle.app ]; then
  echo "  /Applications/Rectangle.app: yes"
else
  echo "  /Applications/Rectangle.app: MISSING"
fi
pgrep -lx Rectangle || echo "  Rectangle process NOT running"
echo

echo "==== 6. Rectangle's actual shortcut bindings ===="
if [ -f "$HOME/Library/Preferences/com.knollsoft.Rectangle.plist" ]; then
  for key in leftHalf rightHalf maximize topHalf bottomHalf; do
    val=$(defaults read com.knollsoft.Rectangle "$key" 2>/dev/null || echo "(unset)")
    printf "  %-12s = %s\n" "$key" "$(printf '%s' "$val" | tr -d '\n' | tr -s ' ')"
  done
else
  echo "  Rectangle preferences file does not exist (has it been launched?)"
fi
echo

echo "==== 7. Rectangle Accessibility permission ===="
# TCC is protected; best we can do is check whether Rectangle is listed at all.
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%Rectangle%';" 2>/dev/null \
  | sed 's/^/  /' \
  || echo "  (cannot read user TCC.db; check System Settings -> Privacy & Security -> Accessibility)"
echo

echo "==== 8. Karabiner grabber log tail (last 20 lines) ===="
LOG="$HOME/.local/share/karabiner/log/console_user_server.log"
if [ -f "$LOG" ]; then
  tail -20 "$LOG"
else
  echo "  no karabiner console_user_server log at $LOG"
fi

log_completed_execution
