#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Load only the helper, without common.sh's root checks or initialization.
eval "$(sed -n '/^ensure_packages_installed()/,/^}/p' "$REPO_DIR/linux/common.sh")"

fail() { echo "FAIL: $*" >&2; exit 1; }
log_info() { :; }
log_debug() { :; }

dpkg-query() {
  case "${*: -1}" in
    realmd) printf '%s' 'install ok installed' ;;
    held) printf '%s' 'hold ok installed' ;;
    sudo) printf '%s' 'deinstall ok config-files' ;;
    unpacked) printf '%s' 'install ok unpacked' ;;
    half-configured) printf '%s' 'install ok half-configured' ;;
    absent) return 1 ;;
    *) fail "Unexpected package query: $*" ;;
  esac
}

apt_calls=()
apt() {
  apt_calls+=("$*")
  if [ "$1" = install ]; then
    [ "${DEBIAN_FRONTEND:-}" = noninteractive ] || fail "Installation must remain noninteractive"
  fi
}

ensure_packages_installed realmd sudo unpacked half-configured absent
[ "${#apt_calls[@]}" -eq 2 ] || fail "Missing packages must trigger APT update and installation"
[ "${apt_calls[0]}" = update ] || fail "APT metadata must be updated first"
[ "${apt_calls[1]}" = 'install -y sudo unpacked half-configured absent' ] || fail "All non-installed packages, including removed sudo, must be installed"

apt_calls=()
ensure_packages_installed realmd held
[ "${#apt_calls[@]}" -eq 0 ] || fail "Installed packages must not trigger APT"

echo "Common package installation tests passed."
