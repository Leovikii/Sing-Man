#!/bin/bash
# shellcheck disable=SC2034
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for file in config.sh lib/sys.sh lib/log.sh lib/svc.sh modules/sb.sh; do
    # shellcheck disable=SC1090,SC1091
    source "$ROOT_DIR/shell/src/$file"
done

# 宿主机集成测试：使用独立原生 unit，不触碰用户的 sing-box 服务。
if [[ "${1:-}" == --systemd ]]; then
    set -e
    [[ "$EUID" -eq 0 ]] && sys::has_systemd
    unit="sm-autostart-test-$$.service"
    unit_file="/etc/systemd/system/$unit"
    cleanup_unit() {
        systemctl stop "$unit" || true
        systemctl disable "$unit" || true
        rm -f -- "$unit_file"
        systemctl daemon-reload
        systemctl reset-failed "$unit" 2>/dev/null || true
    }
    trap cleanup_unit EXIT
    printf '%s\n' '[Service]' 'ExecStart=/bin/sleep 600' '[Install]' 'WantedBy=multi-user.target' > "$unit_file"
    systemctl daemon-reload
    [[ "$(svc::autostart_state "$unit")" == disabled ]]
    svc::set_autostart "$unit" enabled
    ! svc::is_active "$unit"
    svc::start "$unit"
    svc::is_active "$unit"
    svc::set_autostart "$unit" disabled
    svc::is_active "$unit"
    svc::restart "$unit"
    [[ "$(svc::autostart_state "$unit")" == disabled ]]
    svc::stop "$unit"
    ! svc::is_active "$unit"
    svc::set_autostart "$unit" enabled
    ! svc::is_active "$unit"
    svc::set_autostart "$unit" disabled
    rm -- "$unit_file"
    systemctl mask "$unit"
    [[ "$(svc::autostart_state "$unit")" == masked ]]
    ! svc::set_autostart "$unit" enabled
    echo 'ok - native systemd enable/disable, runtime independence and masked service'
    exit 0
fi

PASS=0; FAIL=0
run_test() {
    local name="$1"; shift
    if ("$@"); then printf 'ok - %s\n' "$name"; ((PASS += 1))
    else printf 'not ok - %s\n' "$name" >&2; ((FAIL += 1)); fi
}
setup() {
    PLATFORM=debian
    RED=""; GREEN=""; YELLOW=""; PLAIN=""
    boot=disabled; active=0; query_rc=1; action_fail=0
    log::info() { :; }; log::warn() { :; }; log::err() { :; }
    sys::has_systemd() { return 0; }
    timeout() { shift; "$@"; }
    systemctl() {
        case "$1" in
            is-enabled) echo "$boot"; return "$query_rc" ;;
            is-active) [[ "$active" -eq 1 ]] ;;
            enable) [[ "$action_fail" -eq 0 ]] || return 1; boot=enabled; query_rc=0 ;;
            disable) [[ "$action_fail" -eq 0 ]] || return 1; boot=disabled; query_rc=1 ;;
            start|restart) active=1 ;;
            stop) active=0 ;;
            *) return 1 ;;
        esac
    }
    svc::wait_active() { svc::is_active "$1"; }
}

test_systemd_states() {
    setup
    local state
    for state in enabled disabled masked masked-runtime static enabled-runtime indirect alias generated transient linked linked-runtime not-found; do
        boot="$state"
        [[ "$(svc::autostart_state sing-box)" == "$state" ]] || return 1
    done
    query_rc=124; boot=disabled
    ! svc::autostart_state sing-box > /dev/null || return 1
    [[ "$(svc::autostart_state sing-box)" == unknown ]] || return 1
    boot='Failed to connect'; query_rc=1
    [[ "$(svc::autostart_state sing-box)" == unknown ]] || return 1
    sys::has_systemd() { return 1; }
    [[ "$(svc::autostart_state sing-box)" == unavailable ]]
}
test_systemd_actions() {
    setup
    svc::set_autostart sing-box enabled || return 1
    [[ "$boot" == enabled && "$active" -eq 0 ]] || return 1
    svc::start sing-box && svc::set_autostart sing-box disabled || return 1
    [[ "$boot" == disabled && "$active" -eq 1 ]] || return 1
    svc::restart sing-box && svc::stop sing-box || return 1
    [[ "$boot" == disabled ]] || return 1
    boot=masked
    ! svc::set_autostart sing-box enabled || return 1
    [[ "$boot" == masked ]] || return 1
    boot=static
    systemctl() { [[ "$1" == is-enabled ]] && echo static; return 0; }
    ! svc::set_autostart sing-box enabled
}
test_action_failure() {
    setup
    action_fail=1
    ! svc::set_autostart sing-box enabled || return 1
    [[ "$boot" == disabled && "$active" -eq 0 ]]
}
test_debian_install_update() {
    setup
    local installed=1 package_fail=0
    sys::has_cmd() { [[ "$installed" -eq 1 ]]; }
    mkdir() { :; }
    dpkg() { echo amd64; }
    pkg::add_gpg_key() { :; }; pkg::write_repo() { :; }; pkg::update() { :; }
    pkg::install() { installed=1; boot=enabled; query_rc=0; active=1; return "$package_fail"; }
    active=1
    sb::install || return 1
    [[ "$boot" == disabled && "$active" -eq 1 ]] || return 1
    active=0
    sb::install || return 1
    [[ "$boot" == disabled && "$active" -eq 0 ]] || return 1
    package_fail=1
    ! sb::install || return 1
    [[ "$boot" == disabled && "$active" -eq 0 ]] || return 1
    package_fail=0; installed=0; boot=not-found
    sb::install || return 1
    [[ "$boot" == enabled && "$active" -eq 1 ]]
}
setup_openwrt() {
    setup
    PLATFORM=openwrt
    test_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$test_root"' EXIT
    export TEST_BOOT_FILE="$test_root/boot" TEST_ACTIVE_FILE="$test_root/active"
    SB_INIT_FILE="$test_root/init"
    cat > "$SB_INIT_FILE" <<'INIT'
#!/bin/bash
case "$1" in
    enabled) [[ -f "$TEST_BOOT_FILE" ]] ;;
    enable) touch "$TEST_BOOT_FILE" ;;
    disable) rm -f "$TEST_BOOT_FILE" ;;
    start|restart) touch "$TEST_ACTIVE_FILE" ;;
    stop) rm -f "$TEST_ACTIVE_FILE" ;;
esac
INIT
    chmod +x "$SB_INIT_FILE"
    sys::has_procd() { return 0; }
    uci_value=1; uci_fail=0
    uci() {
        case "$*" in
            '-q export sing-box') [[ "$uci_fail" -eq 0 ]] ;;
            '-q get sing-box.main.enabled') echo "$uci_value" ;;
            'set sing-box.main.enabled='*) uci_value="${2#*=}" ;;
            'commit sing-box') return 0 ;;
            *) return 1 ;;
        esac
    }
}
test_procd_states() {
    setup_openwrt
    [[ "$(svc::autostart_state sing-box)" == disabled ]] || return 1
    touch "$TEST_BOOT_FILE"
    local value
    for value in 1 true yes on enabled; do
        uci_value="$value"
        [[ "$(svc::autostart_state sing-box)" == enabled ]] || return 1
        svc::restart sing-box || return 1
        [[ -e "$TEST_BOOT_FILE" ]] || return 1
    done
    for value in 0 false no off disabled ''; do
        uci_value="$value"
        [[ "$(svc::autostart_state sing-box)" == blocked ]] || return 1
    done
    uci_fail=1
    [[ "$(svc::autostart_state sing-box)" == unknown ]] || return 1
    timeout() { return 124; }
    [[ "$(svc::autostart_state sing-box)" == unknown ]]
}
test_procd_independence() {
    setup_openwrt
    svc::set_autostart sing-box enabled || return 1
    [[ ! -e "$TEST_ACTIVE_FILE" ]] || return 1
    svc::start sing-box && svc::set_autostart sing-box disabled || return 1
    [[ -e "$TEST_ACTIVE_FILE" && "$uci_value" == 1 ]] || return 1
    svc::restart sing-box || return 1
    [[ "$(svc::autostart_state sing-box)" == disabled ]] || return 1
    svc::stop sing-box
    [[ "$(svc::autostart_state sing-box)" == disabled && ! -e "$TEST_ACTIVE_FILE" ]]
}
test_blocked_manual_start() {
    setup_openwrt
    touch "$TEST_BOOT_FILE"
    uci_value=0
    svc::start sing-box || return 1
    [[ "$uci_value" == 1 && -e "$TEST_ACTIVE_FILE" && "$(svc::autostart_state sing-box)" == disabled ]] || return 1
    svc::restore_autostart sing-box blocked || return 1
    [[ "$(svc::autostart_state sing-box)" == blocked ]] || return 1
    svc::set_autostart sing-box enabled || return 1
    [[ "$uci_value" == 1 && "$(svc::autostart_state sing-box)" == enabled ]]
}
run_test 'systemd native states and query errors' test_systemd_states
run_test 'systemd startup and runtime are independent' test_systemd_actions
run_test 'native action failures are propagated' test_action_failure
run_test 'APT install/update/failure preserve startup and runtime' test_debian_install_update
run_test 'procd states, native UCI booleans and query errors' test_procd_states
run_test 'procd startup and runtime are independent' test_procd_independence
run_test 'manual start of UCI-blocked service keeps startup off' test_blocked_manual_start
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
