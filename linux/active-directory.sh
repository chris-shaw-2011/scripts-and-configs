#!/usr/bin/env bash
#
# active-directory.sh
#
# Joins a supported Ubuntu or Debian host to AD with SSSD.

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${ACTIVE_DIRECTORY_TESTING:-0}" != "1" ]; then
  # load shared helpers and require root
  . "$SCRIPT_DIR/common.sh" "$SCRIPT_NAME" "$@"
fi

readonly AD_PACKAGES=(
  realmd
  packagekit
  sssd-ad
  sssd-tools
  adcli
  libnss-sss
  libpam-sss
  samba-common-bin
  krb5-user
  sudo
)
readonly SSSD_DROP_IN=/etc/sssd/conf.d/90-domain-login.conf
readonly SUDOERS_RULE=/etc/sudoers.d/80-ad-domain-admins
readonly AD_COMPLETION_MARKER=/var/lib/active-directory-setup/completed

JOIN_COMPLETED=0

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

normalize_domain() {
  local domain
  domain=$(trim "$1")
  domain=${domain%.}
  printf '%s\n' "${domain,,}"
}

is_valid_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

qualify_ad_name() {
  local name domain local_name supplied_domain
  name=$(trim "$1")
  domain=$(normalize_domain "$2")

  [ -n "$name" ] || return 1
  [[ "$name" != *\\* ]] || return 1

  if [[ "$name" == *@* ]]; then
    local_name=${name%@*}
    supplied_domain=$(normalize_domain "${name##*@}")
    [ -n "$local_name" ] && [ "$supplied_domain" = "$domain" ] || return 1
    printf '%s@%s\n' "$local_name" "$domain"
  else
    printf '%s@%s\n' "$name" "$domain"
  fi
}

is_valid_fqdn_for_domain() {
  local fqdn domain
  fqdn=$(normalize_domain "$1")
  domain=$(normalize_domain "$2")
  [[ "$fqdn" == *.* && "$fqdn" == *".$domain" && "${fqdn%%.*}" != "" ]]
}

platform_from_values() {
  local os_id="$1"
  local os_version="$2"

  if [ "$os_id" = "ubuntu" ] && { [ "$os_version" = "24.04" ] || [ "$os_version" = "26.04" ]; }; then
    printf 'ubuntu-%s\n' "$os_version"
    return 0
  fi

  if [ "$os_id" = "debian" ] && [ "$os_version" = "13" ]; then
    printf '%s\n' "debian-13"
    return 0
  fi

  return 1
}

sudoers_group_rule() {
  local group="$1"
  group=${group//\\/\\\\}
  group=${group//\"/\\\"}
  printf '"%%%s" ALL=(ALL:ALL) ALL\n' "$group"
}

sssd_drop_in_content() {
  local domain="$1"
  cat <<EOF
[domain/$domain]
use_fully_qualified_names = True
cache_credentials = True
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
EOF
}

sssd_services_value() {
  awk '
    /^[[:space:]]*\[/ {
      section = tolower($0)
      in_sssd = section ~ /^[[:space:]]*\[sssd\][[:space:]]*([#;].*)?$/
    }
    in_sssd && tolower($0) ~ /^[[:space:]]*services[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*[#;].*$/, "", value)
      print value
    }
  ' "$1"
}

services_are_realm_defaults() {
  local value="$1"
  local -a services=()
  local service
  local has_nss=0
  local has_pam=0

  value=${value,,}
  value=${value//[[:space:]]/}
  IFS=, read -r -a services <<< "$value"
  [ "${#services[@]}" -ge 2 ] && [ "${#services[@]}" -le 3 ] || return 1

  for service in "${services[@]}"; do
    case "$service" in
      nss) has_nss=1 ;;
      pam) has_pam=1 ;;
      pac) ;;
      *) return 1 ;;
    esac
  done

  [ "$has_nss" -eq 1 ] && [ "$has_pam" -eq 1 ]
}

sssd_normalized_config() {
  awk -v remove_services="${2:-1}" -v remove_config_version="${3:-0}" '
    /^[[:space:]]*\[/ {
      section = tolower($0)
      in_sssd = section ~ /^[[:space:]]*\[sssd\][[:space:]]*([#;].*)?$/
    }
    in_sssd && remove_services && tolower($0) ~ /^[[:space:]]*services[[:space:]]*=/ { next }
    in_sssd && remove_config_version && tolower($0) ~ /^[[:space:]]*config_file_version[[:space:]]*=/ { next }
    { print }
  ' "$1"
}

is_affirmative() {
  case "$1" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

realm_field() {
  local details="$1"
  local field="$2"
  sed -n "s/^[[:space:]]*${field}:[[:space:]]*//p" <<< "$details" | head -n1
}

validate_existing_realm() {
  local details="$1"
  [ "$(realm_field "$details" configured)" = "kerberos-member" ] &&
    [ "$(realm_field "$details" server-software)" = "active-directory" ] &&
    [ "$(realm_field "$details" client-software)" = "sssd" ]
}

recover_permitted_group() {
  local details="$1"
  local policy group group_count
  policy=$(realm_field "$details" login-policy)
  group=$(sed -n 's/^[[:space:]]*permitted-groups:[[:space:]]*//p' <<< "$details")
  group_count=$(sed -n '/^[[:space:]]*permitted-groups:[[:space:]]*[^[:space:]]/p' <<< "$details" | wc -l)

  [ "$policy" = "allow-permitted-logins" ] || return 1
  [ "$group_count" -eq 1 ] && [ -n "$group" ] && [[ "$group" != *,* ]] || return 1
  printf '%s\n' "$group"
}

build_join_args() {
  local domain="$1"
  local join_user="$2"
  local computer_ou="${3:-}"

  JOIN_ARGS=(
    join
    --verbose
    --client-software=sssd
    --membership-software=adcli
    --user="$join_user"
  )
  if [ -n "$computer_ou" ]; then
    JOIN_ARGS+=(--computer-ou="$computer_ou")
  fi
  JOIN_ARGS+=("$domain")
}

detect_supported_platform() {
  local os_id=""
  local os_version=""
  local os_release="${1:-/etc/os-release}"

  if [ -r "$os_release" ]; then
    # shellcheck disable=SC1091
    . "$os_release"
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
  fi

  if ! PLATFORM=$(platform_from_values "$os_id" "$os_version"); then
    log_error "Unsupported platform. This script supports Ubuntu 24.04, Ubuntu 26.04, and Debian 13 (including Debian 13-based Proxmox hosts)."
    log_error "Detected ID=${os_id:-unknown}, VERSION_ID=${os_version:-unknown}."
    return 1
  fi

  log_debug "Detected supported platform: $PLATFORM"
}

require_interactive_terminal() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    log_error "Active Directory setup requires an interactive terminal."
    return 1
  fi
}

require_synchronized_time() {
  local synchronized

  if ! command -v timedatectl >/dev/null 2>&1; then
    log_error "timedatectl is unavailable; cannot verify the clock required by Kerberos."
    return 1
  fi

  synchronized=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
  if [ "$synchronized" != "yes" ]; then
    log_error "The system clock is not synchronized. Kerberos domain joins require accurate time."
    log_error "Configure and verify systemd-timesyncd, chrony, or another NTP client, then rerun this script."
    return 1
  fi
}

require_domain_fqdn() {
  local domain="$1"
  local fqdn short_name suggested

  fqdn=$(hostname -f 2>/dev/null || true)
  short_name=$(hostname -s 2>/dev/null || true)
  suggested="${short_name:-host}.$domain"

  if ! is_valid_fqdn_for_domain "$fqdn" "$domain"; then
    log_error "The current FQDN '${fqdn:-unknown}' is not beneath the AD domain '$domain'."
    if is_proxmox; then
      log_error "Do not rename a Proxmox node automatically. Set its final hostname and /etc/hosts entry before cluster creation."
      log_error "Proxmox does not support changing a node hostname after it has joined a cluster."
    else
      log_error "Set the intended hostname with: hostnamectl set-hostname '$suggested'"
      log_error "Then update DNS and /etc/hosts so 'hostname -f' resolves to that FQDN."
    fi
    return 1
  fi

  if [ -z "$short_name" ] || [ "${#short_name}" -gt 15 ]; then
    log_error "The short hostname '${short_name:-unknown}' must be 15 characters or fewer for the AD computer account."
    return 1
  fi
}

prompt_nonempty() {
  local prompt="$1"
  local value=""

  while [ -z "$value" ]; do
    read -r -p "$prompt" value
    value=$(trim "$value")
    [ -n "$value" ] || log_warn "A value is required."
  done

  printf '%s\n' "$value"
}

prompt_domain() {
  local domain=""

  while :; do
    domain=$(prompt_nonempty "Active Directory DNS domain: ")
    domain=$(normalize_domain "$domain")
    if is_valid_domain "$domain"; then
      printf '%s\n' "$domain"
      return 0
    fi
    log_warn "Enter a DNS domain such as example.com."
  done
}

prompt_qualified_name() {
  local prompt="$1"
  local domain="$2"
  local supplied qualified

  while :; do
    supplied=$(prompt_nonempty "$prompt")
    if qualified=$(qualify_ad_name "$supplied" "$domain"); then
      printf '%s\n' "$qualified"
      return 0
    fi
    log_warn "Enter a short AD name or a name qualified with @$domain; DOMAIN\\name syntax is not accepted."
  done
}

configured_realms() {
  command -v realm >/dev/null 2>&1 || return 0
  realm list --name-only 2>/dev/null | sed '/^[[:space:]]*$/d'
}

backup_authentication_files() {
  local config_root="${1:-/etc}"
  local path

  for path in \
    "$config_root/sssd/sssd.conf" \
    "$config_root/krb5.conf" \
    "$config_root/nsswitch.conf" \
    "$config_root/pam.d/common-account" \
    "$config_root/pam.d/common-auth" \
    "$config_root/pam.d/common-password" \
    "$config_root/pam.d/common-session" \
    "$config_root/pam.d/common-session-noninteractive"; do
    if [ -f "$path" ]; then
      backup_if_exists "$path"
    fi
  done
}

discover_domain() {
  local domain="$1"

  log_info "Discovering Active Directory domain $domain..."
  if ! realm discover --verbose --client-software=sssd --server-software=active-directory "$domain"; then
    log_error "Could not discover $domain through the configured DNS resolver."
    log_error "Configure the host to use AD-integrated DNS and verify its LDAP and Kerberos SRV records, then rerun."
    return 1
  fi
}

configure_realmd_package_installation() {
  local config="${1:-/etc/realmd.conf}"
  local package status tmp source

  # APT installs dependencies; realmd still needs PackageKit to check them.
  # automatic-install=no disables installation, not package resolution.
  for package in "${AD_PACKAGES[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    if [[ "$status" != *" ok installed" ]]; then
      log_error "Required AD package '$package' is not installed; refusing to bypass realmd package installation."
      return 1
    fi
  done

  source=/dev/null
  [ ! -e "$config" ] || source="$config"
  tmp=$(mktemp "$(dirname "$config")/.realmd.conf.XXXXXX")
  if ! awk '
    /^[[:space:]]*\[/ {
      in_service = $0 ~ /^[[:space:]]*\[service\][[:space:]]*$/
      if (in_service && !seen_service) {
        print
        print "automatic-install = no"
        seen_service = 1
        next
      }
    }
    in_service && /^[[:space:]]*automatic-install[[:space:]]*=/ { next }
    { print }
    END {
      if (!seen_service) {
        print "[service]"
        print "automatic-install = no"
      }
    }
  ' "$source" > "$tmp"; then
    rm -f -- "$tmp"
    log_error "Could not update $config; the existing configuration was not changed."
    return 1
  fi
  chown root:root "$tmp"
  chmod 0600 "$tmp"

  if [ -f "$config" ] && cmp -s "$tmp" "$config"; then
    rm -f -- "$tmp"
  else
    backup_if_exists "$config"
    mv -f -- "$tmp" "$config"
    log_info "Disabled realmd automatic package installation in $config; dependencies are managed through APT."
  fi

  if ! systemctl start packagekit; then
    log_error "Could not start PackageKit, which realmd needs to check installed dependencies; enrollment was not attempted."
    return 1
  fi

  # realmd must reload even if the user previously edited the file manually.
  if ! systemctl restart realmd; then
    log_error "Could not restart realmd to load $config; enrollment was not attempted."
    return 1
  fi
}

join_domain() {
  local domain="$1"
  local join_user="$2"
  local computer_ou="$3"

  backup_authentication_files
  build_join_args "$domain" "$join_user" "$computer_ou"

  log_info "Joining $domain as $join_user. realm will prompt for the password directly."
  realm "${JOIN_ARGS[@]}"
  JOIN_COMPLETED=1
}

write_sssd_drop_in() {
  local domain="$1"
  local content tmp

  install -d -o root -g root -m 0755 /etc/sssd/conf.d
  content=$(sssd_drop_in_content "$domain")
  tmp=$(mktemp /etc/sssd/conf.d/.90-domain-login.conf.XXXXXX)
  printf '%s\n' "$content" > "$tmp"
  chown root:root "$tmp"
  chmod 0600 "$tmp"

  if [ -f "$SSSD_DROP_IN" ] && cmp -s "$tmp" "$SSSD_DROP_IN"; then
    rm -f "$tmp"
    chown root:root "$SSSD_DROP_IN"
    chmod 0600 "$SSSD_DROP_IN"
    log_debug "$SSSD_DROP_IN is already current"
  else
    backup_if_exists "$SSSD_DROP_IN"
    mv -f -- "$tmp" "$SSSD_DROP_IN"
    log_info "Updated $SSSD_DROP_IN"
  fi
}

reset_failed_existing_units() {
  local unit load_state
  local -a units=()

  for unit in "$@"; do
    if ! load_state=$(systemctl show --property=LoadState --value "$unit"); then
      log_warn "Could not inspect $unit before resetting its failed state."
      continue
    fi
    [ "$load_state" != not-found ] && [ -n "$load_state" ] || continue
    units+=("$unit")
  done

  if [ "${#units[@]}" -gt 0 ]; then
    systemctl reset-failed "${units[@]}" || log_warn "Could not reset failed state for: ${units[*]}"
  fi
}

normalize_sssd_responder_activation() {
  local config="${1:-/etc/sssd/sssd.conf}"
  local snippet_dir="${2:-/etc/sssd/conf.d}"
  local services tmp sssd_version
  local remove_services=0 remove_config_version=0 sockets_enabled=0

  [ -f "$config" ] || {
    log_error "$config is missing after the realm join."
    return 1
  }

  if systemctl is-enabled --quiet sssd-nss.socket && systemctl is-enabled --quiet sssd-pam.socket; then
    sockets_enabled=1
    if services=$(sssd_services_value "$config") && [ -n "$services" ]; then
      if ! services_are_realm_defaults "$services"; then
        log_error "Refusing to remove the customized SSSD services directive: $services"
        log_error "Reconcile /etc/sssd/sssd.conf with the enabled SSSD responder sockets, then rerun this script."
        return 1
      fi

      remove_services=1
    fi
  fi

  if ! sssd_version=$(sssd --version) || [[ ! "$sssd_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    log_error "Could not determine the SSSD version; $config was not changed."
    return 1
  fi
  # realmd 0.17 still writes this obsolete option, removed in SSSD 2.10.
  if dpkg --compare-versions "$sssd_version" ge 2.10; then
    remove_config_version=1
  fi

  tmp=$(mktemp "$(dirname "$config")/.sssd.conf.XXXXXX")
  sssd_normalized_config "$config" "$remove_services" "$remove_config_version" > "$tmp"
  chown root:root "$tmp"
  chmod 0600 "$tmp"
  if cmp -s "$tmp" "$config"; then
    rm -f "$tmp"
  else
    if ! sssctl config-check --config="$tmp" --snippet="$snippet_dir"; then
      rm -f "$tmp"
      log_error "SSSD rejected the configuration cleanup; $config was not changed."
      return 1
    fi
    backup_if_exists "$config"
    mv -f -- "$tmp" "$config"
    log_info "Normalized realm-generated SSSD configuration for SSSD $sssd_version and enabled responder sockets."
  fi

  if [ "$sockets_enabled" -eq 1 ]; then
    reset_failed_existing_units sssd-nss.socket sssd-pam.socket sssd-pam-priv.socket
  fi

  if systemctl is-enabled --quiet sssd-pac.socket; then
    systemctl disable --now sssd-pac.socket
    log_info "Disabled sssd-pac.socket; the AD provider supplies its PAC responder through the main SSSD service."
  fi
  reset_failed_existing_units sssd-pac.socket sssd-pac.service
}

configure_login_group() {
  local domain="$1"
  local group="$2"

  realm deny --realm "$domain" --all
  realm permit --realm "$domain" --groups "$group"
}

enable_home_directories() {
  DEBIAN_FRONTEND=noninteractive pam-auth-update --package --enable mkhomedir
  if ! grep -Eq '^[[:space:]]*session[[:space:]].*pam_mkhomedir\.so' /etc/pam.d/common-session; then
    log_error "The mkhomedir PAM profile was not enabled, possibly because common-session has local modifications."
    log_error "Review the PAM changes and run 'pam-auth-update --enable mkhomedir' manually, then rerun this script."
    return 1
  fi
}

write_sudoers_rule() {
  local group="$1"
  local content tmp

  content=$(sudoers_group_rule "$group")
  tmp=$(mktemp /etc/sudoers.d/.80-ad-domain-admins.XXXXXX)
  printf '%s\n' "$content" > "$tmp"
  chown root:root "$tmp"
  chmod 0440 "$tmp"

  if ! visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    log_error "Generated sudoers policy did not pass validation; no sudoers change was made."
    return 1
  fi

  if [ -f "$SUDOERS_RULE" ] && cmp -s "$tmp" "$SUDOERS_RULE"; then
    rm -f "$tmp"
    chown root:root "$SUDOERS_RULE"
    chmod 0440 "$SUDOERS_RULE"
    log_debug "$SUDOERS_RULE is already current"
  else
    backup_if_exists "$SUDOERS_RULE"
    mv -f -- "$tmp" "$SUDOERS_RULE"
    log_info "Updated $SUDOERS_RULE"
  fi

  visudo -cf /etc/sudoers >/dev/null
}

validate_test_identity() {
  local user="$1"
  local group="$2"
  local group_gid user_gids

  getent passwd "$user" >/dev/null || {
    log_error "AD user '$user' was not resolved through NSS."
    return 1
  }
  getent group "$group" >/dev/null || {
    log_error "Allowed AD group '$group' was not resolved through NSS."
    return 1
  }

  group_gid=$(getent group "$group" | awk -F: 'NR == 1 { print $3 }')
  user_gids=$(id -G "$user")
  if ! grep -qw -- "$group_gid" <<< "$user_gids"; then
    log_error "AD user '$user' is not a direct or nested member of '$group'."
    return 1
  fi
}

validate_pam_services() {
  local user="$1"
  local service

  for service in login sshd gdm-password xrdp-sesman; do
    [ -f "/etc/pam.d/$service" ] || continue
    log_info "Checking SSSD account access through PAM service $service..."
    sssctl user-checks --action=acct --service="$service" "$user" >/dev/null || return $?
  done
}

inspect_ssh_policy() {
  local group="$1"
  local config password_auth use_pam

  if ! command -v sshd >/dev/null 2>&1 || [ ! -f /etc/pam.d/sshd ]; then
    log_warn "OpenSSH Server is not installed; SSH login was not configured or tested."
    return 0
  fi

  if ! config=$(sshd -T 2>/dev/null); then
    log_warn "Could not inspect the effective sshd configuration; run 'sshd -T' manually."
    return 0
  fi

  password_auth=$(awk '$1 == "passwordauthentication" { print $2; exit }' <<< "$config")
  use_pam=$(awk '$1 == "usepam" { print $2; exit }' <<< "$config")

  [ "$password_auth" = "yes" ] || log_warn "SSH password authentication is disabled; domain users need another SSH authentication method."
  [ "$use_pam" = "yes" ] || log_warn "sshd UsePAM is disabled; SSSD account restrictions may not be applied to SSH."

  if grep -Eq '^(allowusers|allowgroups)[[:space:]]' <<< "$config"; then
    log_warn "sshd has AllowUsers or AllowGroups restrictions; confirm that they include '$group'."
  fi
}

validate_configuration() {
  local domain="$1"
  local group="$2"
  local user="$3"
  local details configured_domain

  configured_domain=$(configured_realms) || return $?
  [ "$(normalize_domain "$configured_domain")" = "$domain" ] || {
    log_error "realm does not report $domain as the sole configured realm."
    return 1
  }
  details=$(realm list) || return $?
  validate_existing_realm "$details" || {
    log_error "realm does not report a configured Active Directory SSSD membership for $domain."
    return 1
  }
  [ "$(recover_permitted_group "$details")" = "$group" ] || {
    log_error "realm does not report '$group' as the sole permitted login group."
    return 1
  }

  sssctl config-check || return $?
  systemctl is-active --quiet sssd || return $?
  if systemctl is-failed --quiet sssd-nss.socket sssd-pam.socket sssd-pam-priv.socket sssd-pac.socket sssd-pac.service; then
    log_error "One or more SSSD responder units remain failed."
    return 1
  fi
  validate_test_identity "$user" "$group" || return $?
  validate_pam_services "$user" || return $?
  sudo -l -U "$user" >/dev/null || return $?
  inspect_ssh_policy "$group"
}

on_error() {
  local status=$?
  if [ "$JOIN_COMPLETED" -eq 1 ]; then
    log_error "The AD join succeeded, but a later configuration or validation step failed."
    log_error "The host remains joined to the domain; fix the reported issue and rerun this script."
  fi
  exit "$status"
}

ad_setup_completed() {
  [ -f "${1:-$AD_COMPLETION_MARKER}" ]
}

mark_ad_setup_completed() {
  local domain="$1"
  local marker="${2:-$AD_COMPLETION_MARKER}"
  local state_dir tmp

  state_dir=$(dirname "$marker")
  install -d -o root -g root -m 0700 "$state_dir"
  tmp=$(mktemp "$state_dir/.completed.XXXXXX")
  printf '%s\n' "$domain" > "$tmp"
  chown root:root "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$marker"
}

main() {
  local -a realms=()
  local realm_details=""
  local domain=""
  local join_user=""
  local computer_ou=""
  local allowed_group=""
  local test_user=""
  local answer=""
  local realm_output=""
  local existing_join=0

  set -E
  trap on_error ERR

  if ad_setup_completed; then
    log_info "Active Directory login setup previously completed successfully; skipping."
    log_completed_execution
    return 0
  fi

  require_interactive_terminal

  realm_output=$(configured_realms)
  if [ -n "$realm_output" ]; then
    mapfile -t realms <<< "$realm_output"
  fi
  if [ "${#realms[@]}" -gt 1 ]; then
    log_error "Multiple configured realms are not supported: ${realms[*]}"
    return 1
  fi

  if [ "${#realms[@]}" -eq 1 ]; then
    domain=$(normalize_domain "${realms[0]}")
    realm_details=$(realm list)
    if ! validate_existing_realm "$realm_details"; then
      log_error "The existing realm '${realms[0]}' is not an Active Directory SSSD membership."
      return 1
    fi
    existing_join=1
    log_info "Reusing existing Active Directory membership for $domain."
  else
    read -r -p "Configure Active Directory login on this host? [y/N]: " answer
    if ! is_affirmative "$answer"; then
      log_info "Skipping Active Directory configuration."
      log_completed_execution
      return 0
    fi
    domain=$(prompt_domain)
  fi

  detect_supported_platform
  require_synchronized_time
  require_domain_fqdn "$domain"
  ensure_packages_installed "${AD_PACKAGES[@]}"
  if [ "$existing_join" -eq 0 ]; then
    configure_realmd_package_installation
  fi
  discover_domain "$domain"

  if [ "$existing_join" -eq 0 ]; then
    read -r -p "Domain join account [Administrator]: " join_user
    join_user=$(trim "$join_user")
    join_user=${join_user:-Administrator}
    read -r -p "Computer OU distinguished name (optional): " computer_ou
    computer_ou=$(trim "$computer_ou")
  fi

  if [ "$existing_join" -eq 1 ] && allowed_group=$(recover_permitted_group "$realm_details"); then
    allowed_group=$(qualify_ad_name "$allowed_group" "$domain") || {
      log_error "The existing permitted group '$allowed_group' is not valid for $domain."
      return 1
    }
    log_info "Using existing permitted AD group: $allowed_group"
  else
    allowed_group=$(prompt_qualified_name "AD group allowed to log in: " "$domain")
  fi
  test_user=$(prompt_qualified_name "Representative AD user in $allowed_group: " "$domain")

  if [ "$existing_join" -eq 0 ]; then
    join_domain "$domain" "$join_user" "$computer_ou"
  fi

  validate_test_identity "$test_user" "$allowed_group"
  write_sssd_drop_in "$domain"
  configure_login_group "$domain" "$allowed_group"
  normalize_sssd_responder_activation
  enable_home_directories
  write_sudoers_rule "$allowed_group"
  sssctl config-check
  systemctl restart sssd
  validate_configuration "$domain" "$allowed_group" "$test_user" || return $?
  mark_ad_setup_completed "$domain"

  log_info "Active Directory login configuration completed successfully."
  log_info "Use fully qualified login names such as $test_user."
  log_info "Keep this administrator session open while testing SSH, terminal, GDM, or XRDP login in a second session."
  log_completed_execution
}

if [ "${ACTIVE_DIRECTORY_TESTING:-0}" != "1" ]; then
  main "$@"
fi
