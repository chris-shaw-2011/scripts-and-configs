#!/usr/bin/env bash
# Common helpers for the macOS scripts.
#
# Mirrors linux/common.sh in spirit, but:
#   - macOS scripts run as the regular logged-in user (NOT root);
#     Karabiner-Elements config and the per-user `defaults` database
#     are user-scoped.
#   - Bails out if not running on macOS (Darwin).

# Fail on unset, non-zero exit, and make pipelines fail on first failure
set -eu -o pipefail

# Debug mode (set to 1 to enable debug output)
DEBUG=0

CALLING_SCRIPT="${1:-}"

# Color codes (use $'...' so escape sequences are actual bytes)
readonly COLOR_RESET=$'\e[0m'
readonly COLOR_WARN=$'\e[33m'   # yellow
readonly COLOR_ERROR=$'\e[31m'  # red
readonly COLOR_DEBUG=$'\e[90m'  # bright black / grey

log_info() {
  echo "$@"
}

log_warn() {
  echo -e "${COLOR_WARN}$*${COLOR_RESET}" >&2
}

log_error() {
  echo -e "${COLOR_ERROR}$*${COLOR_RESET}" >&2
}

log_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo -e "${COLOR_DEBUG}$*${COLOR_RESET}" >&2
  fi
}

log_completed_execution() {
  log_debug "${CALLING_SCRIPT}: completed execution."
}

export DEBUG

# Check for --debug flag in arguments
if [[ " $* " == *" --debug "* ]]; then
  DEBUG=1
  export DEBUG
  log_debug "Debug mode enabled"
fi

if [ -n "$CALLING_SCRIPT" ]; then
  log_debug "$CALLING_SCRIPT: starting execution..."
else
  log_debug "common.sh: starting execution..."
  log_warn "No calling script name provided to common.sh; debug messages may be less informative."
fi

# Refuse to run on non-macOS
if [ "$(uname -s)" != "Darwin" ]; then
  log_error "This script must be run on macOS (Darwin). Detected: $(uname -s)"
  log_completed_execution
  exit 1
fi

# Refuse to run as root: macOS user-scoped settings (defaults, Karabiner)
# would end up writing to the root user's home, not the actual user's.
if [ "$(id -u)" -eq 0 ]; then
  log_error "This script must NOT be run as root / with sudo."
  log_error "Run it as your normal user: ./$(basename "${0:-setup.sh}")"
  log_completed_execution
  exit 1
fi

timestamp() {
  date +%Y-%m-%dT%H-%M-%S
}

backup_if_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    local backup_path="${path}.$(timestamp).bak"
    cp "$path" "$backup_path"
    log_info "Backed up $path -> $backup_path"
  fi
}

# Write `content` to `path` only if the file is missing or its content differs.
# Backs up the existing file (if any) before overwriting.
# Returns 0 if no change was needed, 1 if a change was made.
write_file_if_changed() {
  local path="$1"
  local content="$2"

  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    log_debug "No changes needed for $path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  backup_if_exists "$path"
  printf '%s\n' "$content" > "$path"
  log_info "Updated $path"
  return 1
}

# Copy `src` to `dst` only if missing or different.
# Backs up an existing dst before overwriting.
# Returns 0 if no change was needed, 1 if a change was made.
copy_file_if_changed() {
  local src="$1"
  local dst="$2"

  if [ ! -f "$src" ]; then
    log_error "Source file missing: $src"
    return 2
  fi

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    log_debug "No changes needed for $dst"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  backup_if_exists "$dst"
  cp "$src" "$dst"
  log_info "Updated $dst"
  return 1
}

# Ensure a Homebrew formula or cask is installed.
#   ensure_brew_package <name> [--cask]
# Returns 0 if installed (either already present or freshly installed).
# Returns 1 if Homebrew is unavailable or the install failed; logs the reason.
ensure_brew_package() {
  local pkg="$1"
  local cask_flag="${2:-}"

  if ! command -v brew >/dev/null 2>&1; then
    log_warn "Homebrew is not installed. Install from https://brew.sh/ and re-run this script."
    return 1
  fi

  if [ "$cask_flag" = "--cask" ]; then
    if brew list --cask --versions "$pkg" >/dev/null 2>&1; then
      log_debug "Cask $pkg already installed"
      return 0
    fi
    log_info "Installing cask $pkg via Homebrew..."
    if brew install --cask "$pkg"; then
      log_info "Installed cask $pkg"
      return 0
    fi
    log_error "Failed to install cask $pkg"
    return 1
  fi

  if brew list --versions "$pkg" >/dev/null 2>&1; then
    log_debug "Formula $pkg already installed"
    return 0
  fi
  log_info "Installing $pkg via Homebrew..."
  if brew install "$pkg"; then
    log_info "Installed $pkg"
    return 0
  fi
  log_error "Failed to install $pkg"
  return 1
}
