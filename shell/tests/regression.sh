#!/bin/bash
# shellcheck disable=SC2034

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
    if ("$@"); then
        printf 'ok - %s\n' "$name"
        ((PASS += 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        ((FAIL += 1))
    fi
}

test_secure_tmp_dir() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    log::err() { :; }
    # shellcheck source=../src/config.sh
    source "$ROOT_DIR/shell/src/config.sh"

    runtime::init_tmp || return 1
    local created="$TMP_DIR" second mode
    mode=$(stat -c '%a' "$created") || return 1
    [[ "$created" == /tmp/sm_manager.* ]] || return 1
    # Windows Git Bash 不模拟 POSIX chmod；Linux/CI 必须严格验证 0700。
    if [[ "$(uname -s)" != MINGW* && "$mode" != "700" ]]; then
        return 1
    fi
    cleanup
    [[ ! -e "$created" ]] || return 1

    TMP_DIR=""
    runtime::init_tmp || return 1
    second="$TMP_DIR"
    [[ "$second" != "$created" ]]
}

test_single_instance_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    log::err() { :; }
    # shellcheck source=../src/config.sh
    source "$ROOT_DIR/shell/src/config.sh"
    LOCK_FILE="/tmp/sm-manager-test-$$.lock"

    runtime::acquire_lock || return 1
    ! flock -n "$LOCK_FILE" -c true || return 1
    cleanup
    flock -n "$LOCK_FILE" -c true || return 1
    rm -f -- "$LOCK_FILE"
}

test_semver_ordering() {
    # shellcheck source=../src/lib/version.sh
    source "$ROOT_DIR/shell/src/lib/version.sh"

    version::is_valid "3.2.8-beta.1" || return 1
    version::is_prerelease "3.2.8-rc.1" || return 1
    version::gt "3.2.8" "3.2.8-rc.9" || return 1
    version::gt "3.2.8-beta.10" "3.2.8-beta.2" || return 1
    version::gt "3.2.8-rc.1" "3.2.8-beta.9" || return 1
    ! version::is_valid "3.2.8-beta.01"
}

test_update_channel_persistence() {
    local state_root current
    state_root=$(mktemp -d) || return 1
    UPDATE_CHANNEL_FILE="$state_root/state/update_channel"
    SCRIPT_VERSION="3.2.7"
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    # shellcheck source=../src/lib/version.sh
    source "$ROOT_DIR/shell/src/lib/version.sh"
    # shellcheck source=../src/self.sh
    source "$ROOT_DIR/shell/src/self.sh"

    current=$(self::get_update_channel) || { rm -rf -- "$state_root"; return 1; }
    [[ "$current" == "stable" ]] || { rm -rf -- "$state_root"; return 1; }
    self::set_update_channel preview || { rm -rf -- "$state_root"; return 1; }
    current=$(self::get_update_channel) || { rm -rf -- "$state_root"; return 1; }
    [[ "$current" == "preview" ]] || { rm -rf -- "$state_root"; return 1; }
    rm -f -- "$UPDATE_CHANNEL_FILE"
    SCRIPT_VERSION="3.2.8-rc.1"
    current=$(self::get_update_channel)
    rm -rf -- "$state_root"
    [[ "$current" == "preview" ]]
}

test_installed_deps_skip_apt() {
    _DEPS_CHECKED=0
    apt_called=0
    sys::has_cmd() { return 0; }
    dpkg-query() { printf 'install ok installed'; }
    # shellcheck source=../src/lib/pkg.sh
    source "$ROOT_DIR/shell/src/lib/pkg.sh"
    pkg::update() { apt_called=1; return 1; }
    pkg::install_quiet() { apt_called=1; return 1; }
    pkg::install() { apt_called=1; return 1; }

    pkg::ensure_deps || return 1
    [[ "$apt_called" -eq 0 && "$_DEPS_CHECKED" -eq 1 ]]
}

test_apt_timeout_options() {
    local capture actual
    capture=$(mktemp) || return 1
    APT_LOCK_TIMEOUT=60
    APT_NETWORK_TIMEOUT=30
    apt-get() { printf '%s\n' "$*" > "$capture"; }
    # shellcheck source=../src/lib/pkg.sh
    source "$ROOT_DIR/shell/src/lib/pkg.sh"

    pkg::update || { rm -f -- "$capture"; return 1; }
    actual=$(<"$capture")
    rm -f -- "$capture"
    [[ "$actual" == *"DPkg::Lock::Timeout=60"* &&
       "$actual" == *"Acquire::https::Timeout=30"* &&
       "$actual" == *"Acquire::Retries=2"* ]]
}

test_systemctl_timeout_and_detection() {
    local capture actual
    capture=$(mktemp) || return 1
    SYSTEMCTL_TIMEOUT=30
    log::err() { :; }
    sys::has_systemd() { return 0; }
    timeout() { printf '%s\n' "$*" > "$capture"; }
    # shellcheck source=../src/lib/svc.sh
    source "$ROOT_DIR/shell/src/lib/svc.sh"

    svc::start sing-box || { rm -f -- "$capture"; return 1; }
    actual=$(<"$capture")
    [[ "$actual" == "30 systemctl start sing-box" ]] || { rm -f -- "$capture"; return 1; }
    sys::has_systemd() { return 1; }
    ! svc::restart sing-box || { rm -f -- "$capture"; return 1; }
    rm -f -- "$capture"
}

test_https_only_downloads() {
    local capture
    capture=$(mktemp) || return 1
    log::err() { :; }
    sys::has_cmd() { [[ "$1" == "curl" ]]; }
    curl() { printf '%s\n' "$*" > "$capture"; }
    # shellcheck source=../src/lib/net.sh
    source "$ROOT_DIR/shell/src/lib/net.sh"

    net::fetch "https://example.com/file" || { rm -f -- "$capture"; return 1; }
    grep -q -- "--proto =https" "$capture" || { rm -f -- "$capture"; return 1; }
    grep -q -- "--proto-redir =https" "$capture" || { rm -f -- "$capture"; return 1; }
    ! net::fetch "http://example.com/file" || { rm -f -- "$capture"; return 1; }
    rm -f -- "$capture"
}

test_gpg_fingerprint_verification() {
    local dest expected
    dest=$(mktemp) || return 1
    rm -f -- "$dest"
    expected="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"
    log::err() { :; }
    # shellcheck source=../src/lib/pkg.sh
    source "$ROOT_DIR/shell/src/lib/pkg.sh"
    net::fetch() { printf 'dummy-key\n'; }
    gpg() {
        printf 'pub:-:2048:1:6D9152172A2B2F0C:0:0::::::\n'
        printf 'fpr:::::::::%s:\n' "$expected"
    }

    pkg::add_gpg_key "https://example.com/key" "$dest" "$expected" || return 1
    [[ -s "$dest" ]] || return 1
    rm -f -- "$dest"
    ! pkg::add_gpg_key "https://example.com/key" "$dest" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

test_sb_install_propagates_failure() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    SAGERNET_GPG_FINGERPRINT="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    log::step() { :; }
    mkdir() { :; }
    dpkg() { printf 'amd64\n'; }
    pkg::add_gpg_key() { return 0; }
    pkg::write_repo() { return 0; }
    pkg::update() { return 0; }
    pkg::install() { return 1; }
    # shellcheck source=../src/modules/sb.sh
    source "$ROOT_DIR/shell/src/modules/sb.sh"

    ! sb::install
}

test_config_restart_failure_rolls_back() {
    local test_root restart_calls=0 content
    test_root=$(mktemp -d) || return 1
    TMP_DIR="$test_root/tmp"
    SB_CONFIG_DIR="$test_root/etc/sing-box"
    SB_CONFIG_FILE="$SB_CONFIG_DIR/config.json"
    CONFIG_URL_FILE="$test_root/state/default_url"
    CONFIG_DATE_FILE="$test_root/state/config_last_update"
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    mkdir -p "$TMP_DIR" "$SB_CONFIG_DIR"
    printf 'old-config\n' > "$SB_CONFIG_FILE"
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    log::step() { :; }
    ui::prompt() { printf -v "$2" 'https://example.com/config.json'; }
    ui::confirm() { return 0; }
    net::download() { printf 'new-config\n' > "$2"; }
    sing-box() { [[ "$1" == "check" ]]; }
    svc::restart() {
        ((restart_calls += 1))
        [[ "$restart_calls" -ge 2 ]]
    }
    svc::is_active() { return 0; }
    # shellcheck source=../src/modules/sb.sh
    source "$ROOT_DIR/shell/src/modules/sb.sh"

    ! sb::update_config_interactive || { rm -rf -- "$test_root"; return 1; }
    content=$(<"$SB_CONFIG_FILE")
    [[ "$content" == "old-config" && ! -e "$CONFIG_URL_FILE" ]] || {
        rm -rf -- "$test_root"
        return 1
    }
    rm -rf -- "$test_root"
}

test_ufw_port_detection() {
    sys::has_cmd() { [[ "$1" == "sshd" ]]; }
    sshd() {
        printf 'port 2222\nport 2200\naddressfamily any\n'
    }
    export SSH_CONNECTION="198.51.100.2 54321 203.0.113.5 2222"
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"

    [[ "$(ufw::_detect_ssh_ports)" == $'2200\n2222' ]]
}

test_ufw_install_uses_detected_ports() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    local capture expected
    capture=$(mktemp) || return 1
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    log::step() { :; }
    sys::has_cmd() { return 1; }
    pkg::update() { return 0; }
    pkg::install_quiet() { return 0; }
    ufw() { return 0; }
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"
    ufw::_get_ssh_ports() { printf '2222\n2200\n'; }
    ufw::allow() { printf '%s/%s\n' "$1" "$2" >> "$capture"; }

    ufw::install || { rm -f -- "$capture"; return 1; }
    expected=$'2222/tcp\n2222/udp\n2200/tcp\n2200/udp\n80/tcp\n80/udp\n443/tcp\n443/udp'
    local actual
    actual=$(<"$capture")
    rm -f -- "$capture"
    [[ "$actual" == "$expected" ]]
}

test_ufw_rule_failure_rolls_back() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    local capture calls=0 actual
    capture=$(mktemp) || return 1
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"
    ufw::_get_ssh_ports() { printf '2222\n'; }
    ufw::_rule_exists() { return 1; }
    ufw::allow() {
        ((calls += 1))
        [[ "$calls" -lt 3 ]]
    }
    ufw() { printf '%s\n' "$*" >> "$capture"; }

    ! ufw::ensure_baseline_rules || { rm -f -- "$capture"; return 1; }
    actual=$(<"$capture")
    rm -f -- "$capture"
    [[ "$actual" == $'--force delete allow 2222/udp\n--force delete allow 2222/tcp' ]]
}

test_ufw_enable_checks_baseline() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    local capture
    capture=$(mktemp) || return 1
    log::info() { :; }
    log::err() { :; }
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"
    ufw::_require() { return 0; }
    ufw::ensure_baseline_rules() { printf 'checked\n' >> "$capture"; }
    ufw() { printf '%s\n' "$*" >> "$capture"; }

    ufw::enable || { rm -f -- "$capture"; return 1; }
    local actual
    actual=$(<"$capture")
    rm -f -- "$capture"
    [[ "$actual" == $'checked\nenable' ]]
}

test_ufw_deletes_only_selected_rule() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    local capture
    capture=$(mktemp) || return 1
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    ui::prompt() { printf -v "$2" '2'; }
    ui::confirm() { return 0; }
    ufw::_require() { return 0; }
    ufw::_status_numbered() {
        printf '[ 1] 22/tcp ALLOW IN Anywhere\n[ 2] 22/tcp DENY IN 192.0.2.1\n'
    }
    ufw() { printf '%s\n' "$*" > "$capture"; }
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"
    ufw::_require() { return 0; }
    ufw::_status_numbered() {
        printf '[ 1] 22/tcp ALLOW IN Anywhere\n[ 2] 22/tcp DENY IN 192.0.2.1\n'
    }

    ufw::delete_rule_interactive || { rm -f -- "$capture"; return 1; }
    local called
    called=$(<"$capture")
    rm -f -- "$capture"
    [[ "$called" == "delete 2" ]]
}

test_ufw_deletes_unique_dual_stack_pair() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    local capture actual
    capture=$(mktemp) || return 1
    log::info() { :; }
    log::warn() { :; }
    log::err() { :; }
    ui::prompt() { printf -v "$2" '1'; }
    ui::confirm() { return 0; }
    ufw() { printf '%s\n' "$*" >> "$capture"; }
    # shellcheck source=../src/modules/ufw.sh
    source "$ROOT_DIR/shell/src/modules/ufw.sh"
    ufw::_require() { return 0; }
    ufw::_status_numbered() {
        printf '[ 1] 443/tcp ALLOW IN Anywhere\n[ 2] 443/tcp (v6) ALLOW IN Anywhere (v6)\n'
    }

    ufw::delete_rule_interactive || { rm -f -- "$capture"; return 1; }
    actual=$(<"$capture")
    rm -f -- "$capture"
    [[ "$actual" == $'delete 2\ndelete 1' ]]
}

run_test "secure temporary directory" test_secure_tmp_dir
run_test "single instance lock" test_single_instance_lock
run_test "SemVer validation and ordering" test_semver_ordering
run_test "update channel persistence" test_update_channel_persistence
run_test "installed dependencies skip apt" test_installed_deps_skip_apt
run_test "apt uses lock and network timeouts" test_apt_timeout_options
run_test "systemctl uses timeout and environment detection" test_systemctl_timeout_and_detection
run_test "downloads require HTTPS redirects" test_https_only_downloads
run_test "GPG key fingerprint is pinned" test_gpg_fingerprint_verification
run_test "Sing-box install failure propagates" test_sb_install_propagates_failure
run_test "config restart failure rolls back" test_config_restart_failure_rolls_back
run_test "SSH ports are detected and deduplicated" test_ufw_port_detection
run_test "UFW install allows detected SSH and web ports" test_ufw_install_uses_detected_ports
run_test "UFW rule failures roll back additions" test_ufw_rule_failure_rolls_back
run_test "UFW enable checks baseline rules" test_ufw_enable_checks_baseline
run_test "UFW deletes only the selected rule" test_ufw_deletes_only_selected_rule
run_test "UFW deletes a unique dual-stack pair" test_ufw_deletes_unique_dual_stack_pair

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
