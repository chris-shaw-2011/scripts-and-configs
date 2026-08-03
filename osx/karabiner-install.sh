#!/usr/bin/env bash
#
# karabiner-install.sh
#
# Installs Karabiner-Elements (if missing) and applies the Windows-style
# complex modification rules from `windows-karabiner.json`.
#
# What this does, idempotently:
#
#   1. Verifies Homebrew is available (instructs the user if not).
#   2. Installs jq via brew if missing (used to merge JSON safely).
#   3. Installs the karabiner-elements cask if missing.
#   4. Copies windows-karabiner.json into Karabiner's "complex_modifications
#      assets" folder so it shows up in the GUI under
#      Karabiner-Elements -> Complex Modifications -> Add predefined rule.
#   5. Injects/updates each rule from windows-karabiner.json into every
#      profile of ~/.config/karabiner/karabiner.json. Rules are matched by
#      their `description` field, so rerunning this script replaces previous
#      versions of the same rule rather than duplicating them.
#   6. Backs up karabiner.json with a timestamped .bak before any change.
#
# Karabiner-Elements watches karabiner.json and reloads automatically.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load shared helpers
. "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"

SOURCE_JSON="$SCRIPT_DIR/windows-karabiner.json"
ASSETS_DIR="$HOME/Library/Application Support/Karabiner/assets/complex_modifications"
ASSET_FILE="$ASSETS_DIR/windows-karabiner.json"
KARABINER_DIR="$HOME/.config/karabiner"
KARABINER_JSON="$KARABINER_DIR/karabiner.json"
KARABINER_APP="/Applications/Karabiner-Elements.app"

if [ ! -f "$SOURCE_JSON" ]; then
  log_error "Source rules file not found: $SOURCE_JSON"
  log_completed_execution
  exit 1
fi

# Sanity-check the source JSON before touching anything.
# (Done before the jq install check below; if jq is missing we fall back to python3,
# which ships with macOS.)
validate_json() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq empty "$file" >/dev/null 2>&1
  else
    /usr/bin/python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" >/dev/null 2>&1
  fi
}

if ! validate_json "$SOURCE_JSON"; then
  log_error "Source rules file is not valid JSON: $SOURCE_JSON"
  log_completed_execution
  exit 1
fi

# ---- Step 1: ensure jq ----
if ! command -v jq >/dev/null 2>&1; then
  log_warn "jq is not installed; attempting to install via Homebrew..."
  if ! ensure_brew_package jq; then
    log_error "jq is required to safely merge karabiner.json. Install via: brew install jq"
    log_completed_execution
    exit 1
  fi
fi

RULE_PREFIX="[windows-karabiner]"

# Every rule in the source must have a description that starts with the
# tag prefix; that's how our merge identifies rules to replace on re-run.
# Fail loudly here rather than silently ship rules that pile up as
# duplicates in every user's karabiner.json.
if ! bad=$(jq -r --arg prefix "$RULE_PREFIX" '
  [.rules[]
    | (.description // "")
    | select(startswith($prefix) | not)] | .[]
' "$SOURCE_JSON"); then
  log_error "Failed to inspect rule descriptions in $SOURCE_JSON"
  log_completed_execution
  exit 1
fi
if [ -n "$bad" ]; then
  log_error "The following rule descriptions in $SOURCE_JSON are missing the '$RULE_PREFIX' prefix:"
  while IFS= read -r line; do
    log_error "  - $line"
  done <<< "$bad"
  log_error "Add the prefix so the installer can identify and replace them on re-run."
  log_completed_execution
  exit 1
fi

# Reject duplicate descriptions in the source; two rules with the same
# description would collapse to one on install and silently drop the other.
if ! dupes=$(jq -r '
  [.rules[].description]
    | group_by(.) | map(select(length > 1) | .[0]) | .[]
' "$SOURCE_JSON"); then
  log_error "Failed to check for duplicate rule descriptions in $SOURCE_JSON"
  log_completed_execution
  exit 1
fi
if [ -n "$dupes" ]; then
  log_error "$SOURCE_JSON contains duplicate rule descriptions:"
  while IFS= read -r line; do
    log_error "  - $line"
  done <<< "$dupes"
  log_completed_execution
  exit 1
fi

# ---- Step 2: ensure Karabiner-Elements ----
if [ ! -d "$KARABINER_APP" ]; then
  log_info "Karabiner-Elements is not installed."
  if ! ensure_brew_package karabiner-elements --cask; then
    log_error "Karabiner-Elements is not installed and Homebrew install failed."
    log_error "Install manually from https://karabiner-elements.pqrs.org/ and re-run."
    log_completed_execution
    exit 1
  fi
  log_warn "On first launch, macOS will prompt you to grant several permissions"
  log_warn "(Input Monitoring, Accessibility, and a system extension approval)."
  log_warn "Until those are granted, the rules will be in karabiner.json but"
  log_warn "no remapping will actually take effect."
else
  log_debug "Karabiner-Elements already installed at $KARABINER_APP"
fi

# ---- Step 3: place asset file for GUI discovery ----
mkdir -p "$ASSETS_DIR"
copy_file_if_changed "$SOURCE_JSON" "$ASSET_FILE" || true

# ---- Step 4: ensure karabiner.json exists ----
if [ ! -f "$KARABINER_JSON" ]; then
  log_info "$KARABINER_JSON does not exist; writing a minimal default."
  mkdir -p "$KARABINER_DIR"
  cat > "$KARABINER_JSON" <<'JSON'
{
    "global": {
        "check_for_updates_on_startup": true,
        "show_in_menu_bar": true,
        "show_profile_name_in_menu_bar": false
    },
    "profiles": [
        {
            "complex_modifications": {
                "parameters": {
                    "basic.simultaneous_threshold_milliseconds": 50,
                    "basic.to_delayed_action_delay_milliseconds": 500,
                    "basic.to_if_alone_timeout_milliseconds": 1000,
                    "basic.to_if_held_down_threshold_milliseconds": 500,
                    "mouse_motion_to_scroll.speed": 100
                },
                "rules": []
            },
            "name": "Default profile",
            "selected": true,
            "simple_modifications": [],
            "fn_function_keys": [],
            "virtual_hid_keyboard": {
                "keyboard_type_v2": "ansi"
            }
        }
    ]
}
JSON
  log_info "Created $KARABINER_JSON"
fi

# Make sure karabiner.json itself is valid JSON before we attempt a merge.
if ! validate_json "$KARABINER_JSON"; then
  log_error "Existing $KARABINER_JSON is not valid JSON. Refusing to modify it."
  log_error "Fix or remove the file and re-run this script."
  log_completed_execution
  exit 1
fi

# ---- Step 5: merge our rules into every profile ----
#
# Every rule in windows-karabiner.json has its description prefixed with
# "[windows-karabiner]". Before appending the current set of rules to each
# profile we delete every rule whose description:
#   1. starts with that prefix (normal case; catches the previous version
#      of each of our rules on re-run), OR
#   2. is exactly one of the current descriptions with the prefix stripped
#      off (transitional case: rules installed before we introduced the
#      prefix), OR
#   3. appears in LEGACY_DESCRIPTIONS below (rules we used to install but
#      have since renamed away — must be added by hand when we rename).

# Descriptions we shipped in older versions of this repo and have since
# renamed. Add new entries here whenever a rule is renamed so re-running
# the installer cleans up the stale copy in every user's karabiner.json.
LEGACY_DESCRIPTIONS=$(cat <<'EOF'
[
  "Option+Left/Right/Up tiles the focused window using native macOS Tahoe tiling (fn+ctrl+arrow, not in Windows App)",
  "Option+Left/Right tiles window (send Ctrl+Option+Cmd+Shift+Arrow, not in Windows App)",
  "In Windows App, left Command behaves as Alt",
  "Linux-style copy/paste in Terminal (Ctrl+Shift+C/V)"
]
EOF
)

DESIRED_RULES=$(jq -c '.rules' "$SOURCE_JSON")
UNPREFIXED_DESCRIPTIONS=$(jq -c --arg prefix "$RULE_PREFIX " '
  [.rules[].description | ltrimstr($prefix)]
' "$SOURCE_JSON")

TMP_OUT=$(mktemp -t karabiner-merged)
trap 'rm -f "$TMP_OUT"' EXIT

jq \
  --argjson desired "$DESIRED_RULES" \
  --arg prefix "$RULE_PREFIX" \
  --argjson unprefixed "$UNPREFIXED_DESCRIPTIONS" \
  --argjson legacy "$LEGACY_DESCRIPTIONS" \
  '
  .profiles |= map(
    .complex_modifications //= {} |
    .complex_modifications.rules //= [] |
    .complex_modifications.rules = (
      ((.complex_modifications.rules)
        | map(select(
            (.description // "") as $d
            | (($d | startswith($prefix)) | not)
              and (($unprefixed | index($d)) | not)
              and (($legacy | index($d)) | not)
          )))
      + $desired
    )
  )
  ' "$KARABINER_JSON" > "$TMP_OUT"

# Validate the merged output before swapping it in.
if ! validate_json "$TMP_OUT"; then
  log_error "Merged karabiner.json failed JSON validation; leaving existing file untouched."
  log_completed_execution
  exit 1
fi

if cmp -s "$KARABINER_JSON" "$TMP_OUT"; then
  log_info "karabiner.json already contains the latest rules; nothing to do."
else
  backup_if_exists "$KARABINER_JSON"
  mv "$TMP_OUT" "$KARABINER_JSON"
  trap - EXIT
  log_info "Updated $KARABINER_JSON"
  log_info "Karabiner-Elements watches this file and will reload automatically."
fi

log_completed_execution
