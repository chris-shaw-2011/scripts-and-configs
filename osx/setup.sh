#!/usr/bin/env bash
#
# setup.sh
#
# Main orchestrator for macOS workstation setup. Configures keyboard
# shortcuts and installs the Karabiner-Elements config that maps macOS
# behavior to feel like Windows (with Linux-style Terminal shortcuts and
# correct modifier handling when RDP-ing into a Windows machine).
#
# GOALS / POLICY:
#
#   - Idempotent: safe to re-run any number of times.
#   - User-scoped: must NOT be run as root (defaults & Karabiner config
#     are per-user). common.sh enforces this.
#   - Backs up any file before overwriting it (timestamped .bak).
#   - Auto-installs missing tools (jq, Karabiner-Elements) via Homebrew
#     if Homebrew is available; otherwise prints clear instructions.
#
# What it sets up:
#
#   - macOS symbolic hotkeys that the Karabiner config relies on:
#       * "Show Launchpad" -> Cmd+Shift+L
#       * "Show Desktop"   -> Cmd+Shift+D
#
#   - Karabiner-Elements complex modifications (windows-karabiner.json):
#       * Windows-style Ctrl shortcuts for macOS apps
#       * Home/End that behaves like Windows in normal apps and like a
#         shell (Ctrl+A / Ctrl+E) in Terminal / iTerm2
#       * PrintScreen for screenshots
#       * F2 to rename in Finder
#       * Tap-Option to open Launchpad
#       * Inside the Microsoft Remote Desktop (Windows App) client:
#           - Option behaves as the Windows key
#           - Cmd  behaves as Alt
#         so RDP sessions feel native.
#
# Usage:
#   cd osx
#   ./setup.sh                     # apply everything (safe defaults)
#   ./setup.sh --debug             # verbose logging
#   ./setup.sh --force-shortcuts   # overwrite any custom bindings for the
#                                  # macOS shortcuts we manage (Cmd+Shift+L,
#                                  # Cmd+Shift+D). Without this flag, if you
#                                  # have a custom binding on one of those,
#                                  # the script warns and leaves it alone.
#   ./setup.sh --reset-shortcuts   # remove the macOS shortcut entries we
#                                  # manage (revert to macOS defaults). The
#                                  # Karabiner install step still runs; note
#                                  # that rules relying on those shortcuts
#                                  # (tap-Option -> Launchpad, Option+D ->
#                                  # Show Desktop) will not work until you
#                                  # re-run without --reset-shortcuts.
#   ./setup.sh --diagnose          # run diagnose-tiling.sh and exit without
#                                  # changing anything.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load shared helpers and refuse to run as root / on non-macOS
. "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"

for arg in "$@"; do
  if [ "$arg" = "--diagnose" ]; then
    exec "$SCRIPT_DIR/diagnose-tiling.sh" "$@"
  fi
done

# If this is a clean git working tree, pull latest changes (fast-forward only).
# Mirrors the linux/setup.sh behavior; uses SETUP_RESTARTED to break the loop.
if [ "${SETUP_RESTARTED:-0}" = "1" ]; then
  log_debug "SETUP_RESTARTED=1; skipping automatic repo update to avoid restart loop"
else
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git not available; skipping automatic repo update for $SCRIPT_DIR"
  else
    if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      log_warn "$SCRIPT_DIR is not a git working tree; skipping automatic repo update"
    else
      if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]; then
        log_warn "Uncommitted changes in $SCRIPT_DIR; skipping git pull to avoid conflicts"
      else
        log_info "Repository is clean — pulling latest changes for $SCRIPT_DIR"
        OLD_HEAD=$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)
        if git -C "$SCRIPT_DIR" pull --ff-only; then
          NEW_HEAD=$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)
          if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
            log_info "Repository updated (HEAD changed). Restarting setup script to apply updates..."
            exec env SETUP_RESTARTED=1 "$SCRIPT_DIR/$SCRIPT_NAME" "$@"
          else
            log_info "Repository up-to-date; no restart needed"
          fi
        else
          log_warn "git pull failed or would require merge; keeping current files"
        fi
      fi
    fi
  fi
fi

log_info "======================================================================"
log_info "macOS Workstation Setup Script"
log_info "======================================================================"
log_info ""

log_info "Step 1: Configuring macOS keyboard shortcuts..."
"$SCRIPT_DIR/keyboard-shortcuts.sh" "$@"
log_info ""

log_info "Step 2: Installing tiling window manager (Rectangle)..."
"$SCRIPT_DIR/tiling-window-manager.sh" "$@"
log_info ""

log_info "Step 3: Installing Karabiner-Elements config..."
"$SCRIPT_DIR/karabiner-install.sh" "$@"
log_info ""

log_info "======================================================================"
log_info "Post-install sanity check"
log_info "======================================================================"

FAILED=0
WARNED=0

check_ok()   { log_info "  ✓ $*"; }
check_warn() { log_warn "  ! $*"; WARNED=1; }
check_fail() { log_error "  ✗ $*"; FAILED=1; }

# Karabiner-Elements running.
if pgrep -x karabiner_grabber >/dev/null 2>&1 \
   || pgrep -f karabiner_console_user_server >/dev/null 2>&1; then
  check_ok "Karabiner-Elements is running"
else
  check_fail "Karabiner-Elements is not running — launch it once from /Applications"
fi

# Our rules present in the active profile.
KJ="$HOME/.config/karabiner/karabiner.json"
if [ -f "$KJ" ]; then
  rule_count=$(jq -r '
    [.profiles[] | select(.selected == true)
      | .complex_modifications.rules[]?
      | select((.description // "") | startswith("[windows-karabiner]"))]
    | length' "$KJ" 2>/dev/null || echo 0)
  expected=$(jq -r '.rules | length' "$SCRIPT_DIR/windows-karabiner.json" 2>/dev/null || echo 0)
  if [ "$rule_count" = "$expected" ] && [ "$expected" -gt 0 ]; then
    check_ok "$rule_count/$expected [windows-karabiner] rules present in active profile"
  else
    check_fail "$rule_count/$expected [windows-karabiner] rules present in active profile"
  fi

  # Verify the tiling rule is sending the expected Ctrl+Option+Arrow.
  tiling_to=$(jq -r '
    .profiles[] | select(.selected == true)
    | .complex_modifications.rules[]?
    | select((.description // "") | test("tiles the focused window"))
    | .manipulators[0].to[0].modifiers // [] | sort | join("+")' "$KJ" 2>/dev/null)
  if [ "$tiling_to" = "control+option" ]; then
    check_ok "Tiling rule sends Ctrl+Option+Arrow"
  else
    check_fail "Tiling rule sends '$tiling_to' (expected 'control+option')"
  fi
else
  check_fail "Karabiner config file not found: $KJ"
fi

# Rectangle installed, running, and configured.
if [ ! -d /Applications/Rectangle.app ]; then
  check_fail "Rectangle is not installed"
elif ! pgrep -x Rectangle >/dev/null 2>&1; then
  check_warn "Rectangle is installed but not running — launch it from /Applications"
elif defaults read com.knollsoft.Rectangle SUHasLaunchedBefore 2>/dev/null | grep -q '^1$' \
     || defaults read com.knollsoft.Rectangle alternateDefaultShortcuts >/dev/null 2>&1; then
  check_ok "Rectangle running and first-run setup complete"
else
  check_warn "Rectangle is running but first-run setup incomplete — click 'Recommended' in Rectangle's window"
fi

log_info ""
if [ "$FAILED" -eq 1 ]; then
  log_error "Setup finished with FAILING checks above. Run './setup.sh --diagnose' for details."
  exit 1
fi
if [ "$WARNED" -eq 1 ]; then
  log_warn "Setup finished with warnings above; follow the instructions to finish setup."
fi

log_info "======================================================================"
log_info "Setup complete."
log_info "======================================================================"
log_info " - macOS shortcuts: Cmd+Shift+L = Launchpad, Cmd+Shift+D = Show Desktop."
log_info " - Karabiner rules from windows-karabiner.json are merged into every"
log_info "   profile of ~/.config/karabiner/karabiner.json."
log_info " - Re-run this script any time windows-karabiner.json changes; rules"
log_info "   are matched by description so they get replaced, not duplicated."
log_info ""
log_info "If Karabiner-Elements was just installed, open it once and grant"
log_info "Input Monitoring + Accessibility permissions in System Settings."
