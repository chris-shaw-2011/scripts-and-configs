#!/usr/bin/env bash
# Merge the macOS-only Ctrl+C binding into VS Code's user keybindings without
# replacing the user's existing bindings or comments.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"

SOURCE_JSON="$SCRIPT_DIR/vscode-keybindings.json"
MARKER_BEGIN="// [windows-karabiner] Ctrl+C editor copy (macOS only)"
MARKER_END="// [windows-karabiner] end Ctrl+C editor copy"

if ! command -v jq >/dev/null 2>&1; then
  if ! ensure_brew_package jq; then
    log_error "jq is required to install the VS Code keybinding."
    exit 1
  fi
fi

if ! jq -e '
  type == "array" and length == 1 and
  .[0].key == "ctrl+c" and
  .[0].command == "editor.action.clipboardCopyAction" and
  (.[0].when | contains("isMac"))
' "$SOURCE_JSON" >/dev/null; then
  log_error "Invalid managed VS Code keybinding source: $SOURCE_JSON"
  exit 1
fi

binding=$(jq '.[0]' "$SOURCE_JSON" | sed 's/^/  /')
binding="${binding%?}},"
managed_block="  $MARKER_BEGIN
$binding
  $MARKER_END"
block_file=$(mktemp "${TMPDIR:-/tmp}/windows-karabiner-binding.XXXXXX")
trap 'rm -f "$block_file"' EXIT
printf '%s\n' "$managed_block" > "$block_file"

install_keybinding() {
  local edition="$1"
  local cli="$2"
  local user_dir="$3"
  local target="$user_dir/keybindings.json"
  local temp_file

  if [ ! -x "$cli" ]; then
    return 1
  fi

  if [ -f "$target" ] && grep -Fq "$MARKER_BEGIN" "$target"; then
    temp_file=$(mktemp "${TMPDIR:-/tmp}/windows-karabiner-keybindings.XXXXXX")
    if ! awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v block_file="$block_file" '
      function print_block(    line) {
        while ((getline line < block_file) > 0) print line
        close(block_file)
      }
      index($0, begin) {
        print_block()
        replacing = 1
        next
      }
      replacing && index($0, end) {
        replacing = 0
        next
      }
      !replacing { print }
      END { if (replacing) exit 42 }
    ' "$target" > "$temp_file"; then
      rm -f "$temp_file"
      log_error "Managed keybinding markers are malformed in $target; left it unchanged."
      exit 1
    fi

    if cmp -s "$target" "$temp_file"; then
      rm -f "$temp_file"
      log_debug "$edition already has the current managed Ctrl+C keybinding"
      return 0
    fi

    backup_if_exists "$target"
    cp "$temp_file" "$target"
    rm -f "$temp_file"
    log_info "Updated context-aware Ctrl+C keybinding in $edition."
    return 0
  fi

  mkdir -p "$user_dir"

  if [ ! -f "$target" ]; then
    write_file_if_changed "$target" "[
$managed_block
]" || true
    log_info "Installed context-aware Ctrl+C keybinding in $edition."
    return 0
  fi

  if [ "$(tr -d '[:space:]' < "$target")" = "[]" ]; then
    write_file_if_changed "$target" "[
$managed_block
]" || true
    log_info "Installed context-aware Ctrl+C keybinding in $edition."
    return 0
  fi

  temp_file=$(mktemp "${TMPDIR:-/tmp}/windows-karabiner-keybindings.XXXXXX")
  if ! awk -v block_file="$block_file" '
    function print_block(    line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    !inserted && /^[[:space:]]*\[[[:space:]]*$/ {
      print
      print_block()
      inserted = 1
      next
    }
    { print }
    END { if (!inserted) exit 42 }
  ' "$target" > "$temp_file"; then
    rm -f "$temp_file"
    log_error "Could not safely find the top-level array in $target; left it unchanged."
    exit 1
  fi

  backup_if_exists "$target"
  cp "$temp_file" "$target"
  rm -f "$temp_file"
  log_info "Installed context-aware Ctrl+C keybinding in $edition."
  return 0
}

installed=0

if install_keybinding \
  "Visual Studio Code" \
  "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  "$HOME/Library/Application Support/Code/User"; then
  installed=1
fi

if install_keybinding \
  "Visual Studio Code Insiders" \
  "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" \
  "$HOME/Library/Application Support/Code - Insiders/User"; then
  installed=1
fi

if [ "$installed" -eq 0 ]; then
  log_info "VS Code is not installed; skipping its context-aware Ctrl+C keybinding."
else
  log_info "VS Code keybinding installed: Ctrl+C copies in editors and interrupts in terminals."
fi

log_completed_execution
