#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

ACTIVE_DIRECTORY_TESTING=1
# shellcheck source=../linux/active-directory.sh
. "$REPO_DIR/linux/active-directory.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_success() {
  local message="$1"
  shift
  "$@" || fail "$message"
}

assert_failure() {
  local message="$1"
  shift
  if "$@"; then
    fail "$message"
  fi
}

assert_equal "realmd packagekit sssd-ad sssd-tools adcli libnss-sss libpam-sss samba-common-bin krb5-user sudo" "${AD_PACKAGES[*]}" "All required AD packages should be installed"

assert_equal "ubuntu-24.04" "$(platform_from_values ubuntu 24.04)" "Ubuntu 24.04 should be supported"
assert_equal "ubuntu-26.04" "$(platform_from_values ubuntu 26.04)" "Ubuntu 26.04 should be supported"
assert_equal "debian-13" "$(platform_from_values debian 13)" "Debian 13 should be supported, including Proxmox hosts"
assert_failure "Ubuntu 22.04 should be rejected" platform_from_values ubuntu 22.04
assert_failure "Debian 12 should be rejected" platform_from_values debian 12
assert_failure "Future Debian releases should require review" platform_from_values debian 14
assert_failure "Other distributions should be rejected" platform_from_values fedora 13

assert_equal "example.com" "$(normalize_domain ' EXAMPLE.COM. ')" "Domains should be normalized"
assert_success "A normal DNS domain should be valid" is_valid_domain example.com
assert_failure "A single-label domain should be rejected" is_valid_domain example
assert_failure "A domain with an empty label should be rejected" is_valid_domain example..com

assert_equal "alice@example.com" "$(qualify_ad_name alice example.com)" "Short users should be qualified"
assert_equal "Linux Admins@example.com" "$(qualify_ad_name 'Linux Admins@EXAMPLE.COM' example.com)" "Qualified groups should preserve their name"
assert_failure "Names from another domain should be rejected" qualify_ad_name alice@other.example example.com
assert_failure "Backslash-qualified names should be rejected" qualify_ad_name 'EXAMPLE\alice' example.com

assert_success "A matching FQDN should be accepted" is_valid_fqdn_for_domain host.example.com example.com
assert_success "A nested matching FQDN should be accepted" is_valid_fqdn_for_domain host.site.example.com example.com
assert_failure "A bare hostname should be rejected" is_valid_fqdn_for_domain host example.com
assert_failure "An unrelated FQDN should be rejected" is_valid_fqdn_for_domain host.other.example other.invalid

assert_equal '"%Linux Admins@example.com" ALL=(ALL:ALL) ALL' "$(sudoers_group_rule 'Linux Admins@example.com')" "Sudoers groups should be quoted"
assert_equal '"%Linux \"Admins\"@example.com" ALL=(ALL:ALL) ALL' "$(sudoers_group_rule 'Linux "Admins"@example.com')" "Sudoers quotes should be escaped"
expected_sssd=$(cat <<'EOF'
[domain/example.com]
use_fully_qualified_names = True
cache_credentials = True
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
EOF
)
assert_equal "$expected_sssd" "$(sssd_drop_in_content example.com)" "The managed SSSD settings should use qualified names"

sssd_config=$(mktemp)
trap 'rm -f "$sssd_config"' EXIT
printf '%s\n' \
  '[sssd]' \
  'domains = example.com' \
  'services = nss, pam' \
  '' \
  '[domain/example.com]' \
  'id_provider = ad' > "$sssd_config"
assert_equal "nss, pam" "$(sssd_services_value "$sssd_config")" "The SSSD services directive should be read only from the sssd section"
assert_success "The standard realm services should be safe to normalize" services_are_realm_defaults "nss, pam"
assert_success "An explicit PAC responder should still be recognized as a realm default" services_are_realm_defaults "pam, pac, nss"
assert_failure "Customized responder lists must be preserved" services_are_realm_defaults "nss, pam, ssh"
expected_without_services=$(cat <<'EOF'
[sssd]
domains = example.com

[domain/example.com]
id_provider = ad
EOF
)
assert_equal "$expected_without_services" "$(sssd_normalized_config "$sssd_config")" "Only the sssd services directive should be removed"
rm -f "$sssd_config"
trap - EXIT

realm_details=$(cat <<'EOF'
example.com
  type: kerberos
  realm-name: EXAMPLE.COM
  domain-name: example.com
  configured: kerberos-member
  server-software: active-directory
  client-software: sssd
  login-policy: allow-permitted-logins
  permitted-groups: Linux Admins@example.com
EOF
)
assert_success "A compatible existing realm should be reusable" validate_existing_realm "$realm_details"
assert_equal "Linux Admins@example.com" "$(recover_permitted_group "$realm_details")" "The sole permitted group should be recovered"
assert_failure "A Winbind realm should not be reused" validate_existing_realm "${realm_details/client-software: sssd/client-software: winbind}"
assert_failure "An allow-all realm should not provide a managed group" recover_permitted_group "${realm_details/allow-permitted-logins/allow-realm-logins}"
assert_failure "Multiple permitted groups should require reconciliation" recover_permitted_group "$realm_details
  permitted-groups: Other Admins@example.com"

build_join_args example.com joiner 'OU=Linux,OU=Servers'
assert_equal "join" "${JOIN_ARGS[0]}" "The join subcommand should be first"
assert_equal "--client-software=sssd" "${JOIN_ARGS[2]}" "The SSSD client should be explicit"
assert_equal "--membership-software=adcli" "${JOIN_ARGS[3]}" "The adcli membership tool should be explicit"
assert_equal "--computer-ou=OU=Linux,OU=Servers" "${JOIN_ARGS[5]}" "The optional OU should be preserved as one argument"
assert_equal "example.com" "${JOIN_ARGS[6]}" "The domain should be the final argument"
if printf '%s\n' "${JOIN_ARGS[@]}" | grep -Eq '(^|-)password($|=)'; then
  fail "The join command must not contain a password argument"
fi

build_join_args example.com joiner ""
assert_equal "6" "${#JOIN_ARGS[@]}" "An empty OU should not add an argument"
assert_success "yes should opt into setup" is_affirmative yes
assert_failure "the default empty answer should skip setup" is_affirmative ""

log_info() { :; }
log_warn() { :; }
log_error() { :; }

# Base OS detection must not depend on Proxmox packages or product versions.
(
  platform_test_file=$(mktemp)
  trap 'rm -f "$platform_test_file"' EXIT
  printf '%s\n' 'ID=debian' 'VERSION_ID=13' > "$platform_test_file"
  is_proxmox() { fail "Compatibility must not depend on Proxmox detection"; }
  log_debug() { :; }
  dpkg-query() { fail "Compatibility must not query Proxmox packages"; }
  pveversion() { fail "Compatibility must not query Proxmox versions"; }
  detect_supported_platform "$platform_test_file"
  assert_equal "debian-13" "$PLATFORM" "Debian 13 should qualify without any Proxmox tooling"
  assert_failure "Missing OS information must be rejected" detect_supported_platform "$platform_test_file.missing"
)

# Keep VE cluster warnings separate from generic Debian/PBS hostname guidance.
(
  hostname() { printf '%s\n' 'host'; }
  log_error() { printf '%s\n' "$*"; }
  is_proxmox() { return 0; }
  guidance=$(require_domain_fqdn example.com && fail "An unqualified hostname must be rejected" || true)
  [[ "$guidance" == *"before cluster creation"* ]] || fail "VE hostname failures must retain cluster guidance"
  [[ "$guidance" != *"hostnamectl set-hostname"* ]] || fail "VE guidance must not suggest renaming an existing node"
  is_proxmox() { return 1; }
  guidance=$(require_domain_fqdn example.com && fail "An unqualified hostname must be rejected" || true)
  [[ "$guidance" == *"hostnamectl set-hostname 'host.example.com'"* ]] || fail "Generic Debian/PBS must receive FQDN guidance"
  [[ "$guidance" != *"cluster creation"* ]] || fail "VE cluster guidance must not apply to generic Debian/PBS"
)

# Normalize a fresh realmd configuration while retaining custom domain settings.
(
  responder_test_dir=$(mktemp -d)
  trap 'rm -rf "$responder_test_dir"' EXIT
  mkdir "$responder_test_dir/conf.d"
  responder_config="$responder_test_dir/sssd.conf"
  printf '%s\n' \
    '[sssd]' \
    'domains = example.com' \
    'config_file_version = 2' \
    'services = nss, pam' \
    '' \
    '[domain/example.com]' \
    'id_provider = ad' > "$responder_config"
  systemctl_calls=""
  systemctl() {
    if [ "$1" = "is-enabled" ]; then
      return 0
    fi
    if [ "$1" = show ]; then
      printf '%s\n' loaded
      return 0
    fi
    systemctl_calls+="$*"$'\n'
  }
  sssctl() {
    [ "$1" = "config-check" ] || fail "The temporary SSSD configuration should be checked"
    assert_failure "Validation must see the obsolete option already removed" grep -q '^config_file_version' "${2#--config=}"
  }
  sssd() { printf '%s\n' '2.10.1'; }
  chown() { :; }
  backup_count=0
  backup_if_exists() {
    cp "$1" "$1.bak"
    backup_count=$((backup_count + 1))
  }

  normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_failure "The normalized config should not retain a services directive" grep -Eq '^[[:space:]]*services[[:space:]]*=' "$responder_config"
  assert_failure "SSSD 2.10 must not retain config_file_version" grep -q '^config_file_version' "$responder_config"
  assert_success "The backup must retain the original obsolete option" grep -Fxq 'config_file_version = 2' "$responder_config.bak"
  assert_success "The backup must retain the original services directive" grep -Fxq 'services = nss, pam' "$responder_config.bak"
  assert_equal '1' "$backup_count" "Both changes must use a single original backup"
  normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_equal '1' "$backup_count" "An unchanged rerun must not replace the original backup"
  assert_success "The normalized config should retain its AD domain" grep -Fxq 'id_provider = ad' "$responder_config"
  assert_success "The duplicate PAC socket should be disabled" grep -Fxq 'disable --now sssd-pac.socket' <<< "$systemctl_calls"
  assert_success "Failed NSS and PAM socket states should be cleared" grep -Fq 'reset-failed sssd-nss.socket sssd-pam.socket sssd-pam-priv.socket' <<< "$systemctl_calls"
  assert_success "Failed PAC states should be cleared" grep -Fq 'reset-failed sssd-pac.socket sssd-pac.service' <<< "$systemctl_calls"

  printf '%s\n' \
    '[sssd]' \
    'domains = example.com' \
    'services = nss, pam, ssh' > "$responder_config"
  assert_failure "Customized responder lists should stop automatic reconciliation" normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_success "Customized responder lists should remain unchanged" grep -Fxq 'services = nss, pam, ssh' "$responder_config"

  # Non-socket installations need the obsolete-option fix as well.
  systemctl() { [ "$1" != is-enabled ]; }
  printf '%s\n' '[sssd]' 'config_file_version = 2' 'services = nss, pam' \
    '# preserve comments' '[domain/example.com]' 'id_provider = ad' > "$responder_config"
  sssd() { printf '%s\n' '2.9.4'; }
  normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_success "Older SSSD must retain config_file_version" grep -Fxq 'config_file_version = 2' "$responder_config"
  assert_success "Non-socket installations must retain services" grep -Fxq 'services = nss, pam' "$responder_config"
  sssd() { printf '%s\n' '2.10.1'; }
  normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_failure "Obsolete option cleanup must not require enabled sockets" grep -q '^config_file_version' "$responder_config"
  assert_success "Obsolete option cleanup must preserve non-socket services" grep -Fxq 'services = nss, pam' "$responder_config"
  assert_success "Obsolete option cleanup must preserve comments" grep -Fxq '# preserve comments' "$responder_config"

  # Unrelated validation failures must leave the original file unchanged.
  printf '%s\n' '[sssd]' 'config_file_version = 2' 'unknown_setting = yes' > "$responder_config"
  original_config=$(< "$responder_config")
  original_backups=$backup_count
  sssctl() { return 1; }
  assert_failure "Other validation issues must not be suppressed" normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_equal "$original_config" "$(< "$responder_config")" "Rejected cleanup must preserve the original configuration"
  assert_equal "$original_backups" "$backup_count" "Rejected cleanup must not replace backups"
  assert_equal '' "$(find "$responder_test_dir" -name '.sssd.conf.*' -print)" "Rejected temporary configuration must be removed"
  sssd() { return 1; }
  assert_failure "Unknown SSSD versions must stop cleanup" normalize_sssd_responder_activation "$responder_config" "$responder_test_dir/conf.d"
  assert_equal "$original_config" "$(< "$responder_config")" "Unknown versions must leave configuration untouched"
)

# Newer SSSD omits the private PAM socket; skip absent units, not real errors.
(
  reset_calls=""
  warnings=""
  log_warn() { warnings+="$*"$'\n'; }
  systemctl() {
    case "$1" in
      show)
        if [ "${*: -1}" = sssd-pam-priv.socket ]; then
          printf '%s\n' not-found
        else
          printf '%s\n' loaded
        fi
        ;;
      reset-failed) reset_calls+="$*"$'\n' ;;
      *) fail "Unexpected systemctl command: $*" ;;
    esac
  }
  reset_failed_existing_units sssd-nss.socket sssd-pam.socket sssd-pam-priv.socket
  assert_equal $'reset-failed sssd-nss.socket sssd-pam.socket\n' "$reset_calls" "Only existing units should be reset"
  assert_equal '' "$warnings" "Missing private PAM socket must not produce a warning"
  reset_calls=""
  reset_failed_existing_units sssd-pam-priv.socket
  assert_equal '' "$reset_calls" "No reset command should run when all units are absent"
  systemctl() {
    if [ "$1" = show ]; then
      printf '%s\n' loaded
    else
      return 1
    fi
  }
  reset_failed_existing_units sssd-pam.socket
  [[ "$warnings" == *'Could not reset failed state'* ]] || fail "Real reset errors must remain visible"
)

realm() { return 1; }
assert_failure "DNS discovery failures should be fatal" discover_domain example.com

# Back up only active authentication files, never earlier backups.
(
  backup_test_dir=$(mktemp -d)
  trap 'rm -rf "$backup_test_dir"' EXIT
  mkdir -p "$backup_test_dir/sssd" "$backup_test_dir/pam.d"
  touch "$backup_test_dir/sssd/sssd.conf" "$backup_test_dir/krb5.conf" "$backup_test_dir/nsswitch.conf"
  for pam_file in common-account common-auth common-password common-session common-session-noninteractive; do
    touch "$backup_test_dir/pam.d/$pam_file" "$backup_test_dir/pam.d/$pam_file.old.bak"
  done
  touch "$backup_test_dir/pam.d/common-custom"
  backed_up=()
  backup_if_exists() { backed_up+=("$1"); }
  backup_authentication_files "$backup_test_dir"
  assert_equal '8' "${#backed_up[@]}" "Only the eight active configuration files should be backed up"
  for path in "${backed_up[@]}"; do
    [[ "$path" != *.bak && "$path" != */common-custom ]] || fail "Backup files and unrelated PAM files must be excluded"
  done
)

# Prepare PackageKit and realmd while preserving unrelated configuration.
(
  realmd_test_dir=$(mktemp -d)
  trap 'rm -rf "$realmd_test_dir"' EXIT
  realmd_config="$realmd_test_dir/realmd.conf"
  backup_count=0
  restart_count=0
  packagekit_start_count=0
  dpkg-query() { printf '%s' 'install ok installed'; }
  chown() { :; }
  backup_if_exists() {
    if [ -f "$1" ]; then
      cp "$1" "$1.bak"
      backup_count=$((backup_count + 1))
    fi
  }
  systemctl() {
    case "$*" in
      'start packagekit') packagekit_start_count=$((packagekit_start_count + 1)) ;;
      'restart realmd')
        [ "$packagekit_start_count" -gt "$restart_count" ] || fail "PackageKit must start before realmd restarts"
        restart_count=$((restart_count + 1))
        ;;
      *) fail "Unexpected service operation: $*" ;;
    esac
  }

  configure_realmd_package_installation "$realmd_config"
  assert_equal $'[service]\nautomatic-install = no' "$(< "$realmd_config")" "Missing config should be created"
  assert_equal '600' "$(stat -c '%a' "$realmd_config")" "The config should be private"
  assert_equal '0' "$backup_count" "Missing config should not create a backup"
  configure_realmd_package_installation "$realmd_config"
  assert_equal '0' "$backup_count" "An unchanged rerun should not create a backup"
  assert_equal '2' "$restart_count" "Realmd should reload even after a manual config edit"
  assert_equal '2' "$packagekit_start_count" "PackageKit startup should be safe on rerun"
  dpkg-query() { printf '%s' 'hold ok installed'; }
  configure_realmd_package_installation "$realmd_config"
  dpkg-query() { printf '%s' 'install ok installed'; }

  printf '%s\n' '# custom configuration' '[users]' 'default-shell = /bin/zsh' \
    '[service]' '# retain this comment' 'automatic-install = yes' \
    'legacy-samba-config = no' ' automatic-install=yes' \
    '[example.com]' 'computer-ou = OU=Linux,DC=example,DC=com' > "$realmd_config"
  configure_realmd_package_installation "$realmd_config"
  assert_success "The original config should be backed up" grep -Fxq 'automatic-install = yes' "$realmd_config.bak"
  assert_success "User settings should be retained" grep -Fxq 'default-shell = /bin/zsh' "$realmd_config"
  assert_success "Other service settings should be retained" grep -Fxq 'legacy-samba-config = no' "$realmd_config"
  assert_success "Comments should be retained" grep -Fxq '# retain this comment' "$realmd_config"
  assert_success "Domain settings should be retained" grep -Fxq 'computer-ou = OU=Linux,DC=example,DC=com' "$realmd_config"
  assert_equal '1' "$(grep -c '^automatic-install = no$' "$realmd_config")" "Only one active setting should remain"
  assert_failure "Enabled automatic installation must be removed" grep -Eq '^[[:space:]]*automatic-install[[:space:]]*=[[:space:]]*yes' "$realmd_config"
  assert_equal '1' "$backup_count" "A changed config should be backed up once"
  configure_realmd_package_installation "$realmd_config"
  assert_equal '1' "$backup_count" "Preserved custom config should be idempotent"

  printf '%s\n' '[users]' 'default-shell = /bin/zsh' > "$realmd_config"
  configure_realmd_package_installation "$realmd_config"
  assert_equal $'[users]\ndefault-shell = /bin/zsh\n[service]\nautomatic-install = no' \
    "$(< "$realmd_config")" "A missing service section should be appended"

  original_config=$(< "$realmd_config")
  original_restarts=$restart_count
  dpkg-query() { printf '%s' 'deinstall ok config-files'; }
  assert_failure "Removed dependencies must stop preparation" configure_realmd_package_installation "$realmd_config"
  assert_equal "$original_config" "$(< "$realmd_config")" "Missing dependencies must leave config untouched"
  assert_equal "$original_restarts" "$restart_count" "Missing dependencies must not restart realmd"
  dpkg-query() { return 1; }
  assert_failure "Absent dependencies must stop preparation" configure_realmd_package_installation "$realmd_config"
  dpkg-query() {
    if [ "${*: -1}" = packagekit ]; then
      return 1
    fi
    printf '%s' 'install ok installed'
  }
  assert_failure "Missing PackageKit must stop preparation" configure_realmd_package_installation "$realmd_config"
  dpkg-query() { printf '%s' 'install ok installed'; }
  systemctl() {
    [ "$*" = 'start packagekit' ] || fail "A failed PackageKit start must prevent restarting realmd"
    return 1
  }
  assert_failure "PackageKit startup failures must stop enrollment" configure_realmd_package_installation "$realmd_config"
  systemctl() { [ "$*" = 'start packagekit' ]; }
  assert_failure "Realmd restart failures must stop enrollment" configure_realmd_package_installation "$realmd_config"
)

# Exercise the unjoined default-no path without touching the host.
(
  state_test_dir=$(mktemp -d)
  trap 'rm -rf "$state_test_dir"' EXIT
  marker="$state_test_dir/state/completed"
  chown() { :; }
  install() {
    mkdir -p "${*: -1}"
    chmod 0700 "${*: -1}"
  }
  assert_failure "A missing completion marker must not skip setup" ad_setup_completed "$marker"
  mark_ad_setup_completed example.com "$marker"
  assert_success "Successful setup must be recorded" ad_setup_completed "$marker"
  assert_equal example.com "$(< "$marker")" "Only the completed domain should be recorded"
  assert_equal 600 "$(stat -c '%a' "$marker")" "Completion state must be private"
  assert_equal 700 "$(stat -c '%a' "$(dirname "$marker")")" "Completion directory must be private"
  assert_equal '' "$(find "$state_test_dir" -name '.completed.*' -print)" "Marker installation must leave no temporary files"
)

# Completion must not mask a failed check inside the final validator.
(
  configured_realms() { printf '%s\n' example.com; }
  realm() { printf '%s\n' "$realm_details"; }
  sssctl() { return 1; }
  systemctl() { fail "Service checks must not run after rejected SSSD configuration"; }
  assert_failure "Configuration validation failure must propagate" validate_configuration example.com 'Linux Admins@example.com' test.user@example.com
  sssctl() { :; }
  systemctl() { return 1; }
  validate_test_identity() { fail "Identity checks must not run when SSSD is inactive"; }
  assert_failure "Inactive SSSD must fail validation" validate_configuration example.com 'Linux Admins@example.com' test.user@example.com
  systemctl() { [ "$1" != is-failed ]; }
  validate_test_identity() { :; }
  validate_pam_services() { return 1; }
  sudo() { fail "Sudo checks must not run after failed PAM checks"; }
  assert_failure "PAM failure must propagate" validate_configuration example.com 'Linux Admins@example.com' test.user@example.com
  validate_pam_services() { :; }
  sudo() { return 1; }
  assert_failure "Sudo failure must propagate" validate_configuration example.com 'Linux Admins@example.com' test.user@example.com
)

ad_setup_completed() { return 1; }
mark_ad_setup_completed() { fail "Declining setup must not mark it complete"; }
log_debug() { :; }
log_completed_execution() { :; }
detect_supported_platform() { PLATFORM=ubuntu-24.04; }
require_interactive_terminal() { :; }
configured_realms() { :; }
ensure_packages_installed() { fail "Declining AD setup must not install packages"; }
configure_realmd_package_installation() { fail "Declining AD setup must not change realmd"; }
main <<< ""
trap - ERR

# Exercise a complete mocked first enrollment and verify all prompts precede the join.
NEW_JOIN_CALLED=0
PACKAGES_INSTALLED=0
REALMD_PREPARED=0
detect_supported_platform() { PLATFORM=debian-13; }
configured_realms() { :; }
require_synchronized_time() { :; }
require_domain_fqdn() { :; }
ensure_packages_installed() { PACKAGES_INSTALLED=1; }
configure_realmd_package_installation() {
  [ "$PACKAGES_INSTALLED" -eq 1 ] || fail "Realmd preparation must follow package installation"
  REALMD_PREPARED=1
}
discover_domain() {
  [ "$REALMD_PREPARED" -eq 1 ] || fail "Realmd must reload before discovery and enrollment"
}
join_domain() {
  [ "$REALMD_PREPARED" -eq 1 ] || fail "Enrollment must follow realmd preparation"
  assert_equal "example.com" "$1" "The prompted domain should be joined"
  assert_equal "Administrator" "$2" "The empty join account should use its default"
  assert_equal "" "$3" "The empty computer OU should be omitted"
  NEW_JOIN_CALLED=1
  JOIN_COMPLETED=1
}
validate_test_identity() {
  [ "$NEW_JOIN_CALLED" -eq 1 ] || fail "Identity validation must run after the join"
  assert_equal "test.user@example.com" "$1" "The representative user should be qualified"
  assert_equal "Linux Admins@example.com" "$2" "The allowed group should be qualified"
}
write_sssd_drop_in() { :; }
configure_login_group() { :; }
normalize_sssd_responder_activation() { :; }
enable_home_directories() { :; }
write_sudoers_rule() { :; }
sssctl() { :; }
systemctl() { :; }
SETUP_VALIDATED=0
SETUP_MARKED=0
validate_configuration() { SETUP_VALIDATED=1; }
mark_ad_setup_completed() {
  [ "$SETUP_VALIDATED" -eq 1 ] || fail "Completion must be recorded only after validation"
  assert_equal example.com "$1" "The completed domain should be recorded"
  SETUP_MARKED=1
}
main <<< $'yes\nexample.com\n\n\nLinux Admins\ntest.user'
trap - ERR
assert_equal 1 "$SETUP_MARKED" "Successful enrollment must mark setup complete"

# A compatible existing membership must be reused rather than joined again.
MOCK_REALM_DETAILS="$realm_details"
configured_realms() { printf '%s\n' example.com; }
realm() {
  case "$*" in
    list)
      printf '%s\n' "$MOCK_REALM_DETAILS"
      ;;
    discover*)
      :
      ;;
    *)
      fail "Unexpected realm command during existing-membership test: $*"
      ;;
  esac
}
require_synchronized_time() { :; }
require_domain_fqdn() { :; }
ensure_packages_installed() { :; }
configure_realmd_package_installation() { fail "Existing joins must not change realmd enrollment settings"; }
discover_domain() { :; }
prompt_qualified_name() { printf '%s\n' test.user@example.com; }
join_domain() { fail "An existing compatible realm must not be joined again"; }
validate_test_identity() { :; }
write_sssd_drop_in() { :; }
configure_login_group() { :; }
enable_home_directories() { :; }
write_sudoers_rule() { :; }
systemctl() { :; }
validate_configuration() { :; }
SETUP_MARKED=0
main <<< ""
trap - ERR
assert_equal 1 "$SETUP_MARKED" "Finishing a partial existing enrollment must mark setup complete"

# A failed validation must remain retryable.
(
  SETUP_MARKED=0
  validate_configuration() { return 1; }
  assert_failure "Failed validation must not report success" main <<< ""
  trap - ERR
  assert_equal 0 "$SETUP_MARKED" "Failed validation must not create completion state"
)

# Once marked complete, no prompts, realm checks, changes, or restarts may run.
(
  ad_setup_completed() { return 0; }
  require_interactive_terminal() { fail "Completed setup must not prompt"; }
  configured_realms() { fail "Completed setup must not inspect realms"; }
  detect_supported_platform() { fail "Completed setup must not recheck the platform"; }
  ensure_packages_installed() { fail "Completed setup must not install packages"; }
  discover_domain() { fail "Completed setup must not rediscover the domain"; }
  validate_configuration() { fail "Completed setup must not verify again"; }
  systemctl() { fail "Completed setup must not restart services"; }
  mark_ad_setup_completed() { fail "Completed setup must not rewrite the marker"; }
  main </dev/null
  trap - ERR
)

echo "Active Directory helper tests passed."
