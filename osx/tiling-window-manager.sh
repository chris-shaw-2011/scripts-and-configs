#!/usr/bin/env bash
#
# tiling-window-manager.sh
#
# Installs Rectangle, a free window manager whose default "Recommended"
# preset binds the shortcuts our Karabiner rule sends when you press
# Option+Left/Right/Up:
#
#   Ctrl+Option+Left   -> Left half
#   Ctrl+Option+Right  -> Right half
#   Ctrl+Option+Up     -> Maximize
#
# macOS Tahoe's own tiling responds to a physical Globe/fn key press,
# which Karabiner cannot reliably synthesize, so Rectangle is the
# reliable path for "Windows-style Snap".
#
# Idempotent: skips reinstall if Rectangle is already installed, only
# launches it if it is not already running, and only prints setup
# instructions if Rectangle has never been configured before.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

. "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$SCRIPT_NAME" "$@"

RECTANGLE_APP="/Applications/Rectangle.app"
RECTANGLE_PLIST="$HOME/Library/Preferences/com.knollsoft.Rectangle.plist"

if [ ! -d "$RECTANGLE_APP" ]; then
  if ! ensure_brew_package rectangle --cask; then
    log_error "Failed to install Rectangle."
    log_error "Install manually from https://rectangleapp.com/ and re-run."
    log_completed_execution
    exit 1
  fi
else
  log_debug "Rectangle already installed at $RECTANGLE_APP"
fi

# Launch Rectangle if it isn't running so its first-run dialog can appear.
if ! pgrep -x Rectangle >/dev/null 2>&1; then
  log_info "Launching Rectangle..."
  /usr/bin/open -a "$RECTANGLE_APP"
  # Give it a moment to appear.
  sleep 2
fi

# Detect whether Rectangle has ever been configured. Rectangle only writes
# shortcut plist entries for shortcuts the user has *customized*; the
# Recommended preset uses built-in defaults, so leftHalf/rightHalf/etc.
# stay absent from the plist forever. The reliable signals that the
# first-run dialog has been dismissed are `SUHasLaunchedBefore` and
# (for a preset explicitly chosen) `alternateDefaultShortcuts`.
NEEDS_SETUP=1
if [ -f "$RECTANGLE_PLIST" ]; then
  if defaults read com.knollsoft.Rectangle SUHasLaunchedBefore 2>/dev/null | grep -q '^1$' \
     || defaults read com.knollsoft.Rectangle alternateDefaultShortcuts >/dev/null 2>&1; then
    NEEDS_SETUP=0
  fi
fi

if [ "$NEEDS_SETUP" -eq 1 ]; then
  log_warn ""
  log_warn "======================================================================"
  log_warn "RECTANGLE FIRST-RUN SETUP REQUIRED"
  log_warn "======================================================================"
  log_warn "Rectangle has been launched but no tiling shortcuts are configured."
  log_warn "To finish setup:"
  log_warn ""
  log_warn "  1. In the Rectangle window that appeared, click 'Recommended'."
  log_warn "  2. When prompted, click 'Open System Settings' and grant Rectangle"
  log_warn "     access under Privacy & Security -> Accessibility."
  log_warn "  3. Verify a Rectangle icon is in your menu bar."
  log_warn ""
  log_warn "Then test: click into any app window and press Option+Left/Right."
  log_warn "======================================================================"
else
  log_info "Rectangle already configured (first-run setup complete)."
fi

log_completed_execution
