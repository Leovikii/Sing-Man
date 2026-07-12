#!/bin/bash

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

test_sb_install_propagates_failure() {
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
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

run_test "secure temporary directory" test_secure_tmp_dir
run_test "installed dependencies skip apt" test_installed_deps_skip_apt
run_test "Sing-box install failure propagates" test_sb_install_propagates_failure
run_test "SSH ports are detected and deduplicated" test_ufw_port_detection
run_test "UFW install allows detected SSH and web ports" test_ufw_install_uses_detected_ports
run_test "UFW deletes only the selected rule" test_ufw_deletes_only_selected_rule

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
