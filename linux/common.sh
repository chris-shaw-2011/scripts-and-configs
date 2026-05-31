#!/usr/bin/env bash
# Common helpers for the linux scripts

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
  log_debug "$CALLING_SCRIPT: starting execution..."
  log_warn "No calling script name provided to common.sh; debug messages may be less informative."
fi

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
	log_error "This script must be run as root (use sudo)." >&2
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

write_file_if_changed() {
  local path="$1"
  local content="$2"
  
  # If file exists and content is identical, do nothing
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    log_debug "No changes needed for $path"
    return 0  # No change
  fi
  
  # File is missing or content differs: back up and write
  backup_if_exists "$path"
  echo "$content" > "$path"
  log_info "Updated $path"
  return 1  # Change made
}

update_alias() {
  local user=$1
  local email=$2
  local file=/etc/aliases
  local desired="${user}: ${email}"

  if grep -q "^${user}:" "$file" 2>/dev/null; then
    local current
    current=$(grep -m1 "^${user}:" "$file" 2>/dev/null || true)
    if [ "$current" = "$desired" ]; then
      log_debug "Alias for ${user} unchanged"
      return 0
    else
      sed -i "s|^${user}:.*|${desired}|" "$file"
      log_info "Updated alias for ${user} -> ${email}"
      return 1
    fi
  else
    echo "$desired" >> "$file"
    log_info "Added alias for ${user} -> ${email}"
    return 1
  fi
}

is_proxmox() {
  if [ -f /etc/pve/.version ] || dpkg -l | awk '$2=="proxmox-ve" && $1 ~ /^ii/ {found=1} END {exit !found}'; then
    return 0
  else
    return 1
  fi
}

get_notification_email() {
    local no_prompt="${1:-}"
    local existing_email=""

    if [ -f /etc/msmtprc ]; then
        existing_email=$(sed -n 's/^user[[:space:]]\+//p' /etc/msmtprc | head -n1 || true)

        if [ -n "$existing_email" ]; then
            log_debug "Using existing email from /etc/msmtprc for notifications: $existing_email"
            echo "$existing_email"
            return 0
        fi
    fi

    # If prompting is disabled, return empty
    if [ -n "$no_prompt" ]; then
        log_debug "Notification email not configured and prompting disabled"
        echo ""
        return 0
    fi

    # Otherwise prompt user (keep prompting until non-empty)
    local email=""
    while [ -z "$email" ]; do
        log_info "Email address not configured. Please enter the email address for notifications:"
        read -p "Email: " email

        if [ -z "$email" ]; then
            log_warn "Email address cannot be empty. Please try again."
        fi
    done

    echo "$email"
}

ensure_symlink() {
  local src="$1"
  local dst="$2"

  if [ -L "$dst" ]; then
    local cur
    cur=$(readlink "$dst") || true
    if [ "$cur" = "$src" ]; then
      log_debug "Symlink $dst already points to $src"
      return 0
    fi
  fi

  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    backup_if_exists "$dst"
  fi

  ln -sf "$src" "$dst"
  log_info "Created symlink: $dst -> $src"
	return 1
}

ensure_packages_installed() {
    local missing=()
    local installed=()
    local pkg

		log_debug "Ensuring following packages are installed: $*"

    for pkg in "$@"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
				if [ "${#installed[@]}" -gt 0 ]; then
						log_debug "Already installed packages: ${installed[*]}"
				fi

        log_info "Installing missing packages: ${missing[*]}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
    else
        log_debug "No packages needed installation, the following are already installed: ${installed[*]}"
    fi
}

export -f backup_if_exists write_file_if_changed update_alias is_proxmox timestamp get_notification_email log_info log_warn log_error log_debug log_completed_execution ensure_symlink ensure_packages_installed
