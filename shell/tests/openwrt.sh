#!/bin/bash
# shellcheck disable=SC2034
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../src/config.sh
source "$ROOT_DIR/shell/src/config.sh"
for file in lib/sys.sh lib/version.sh lib/pkg.sh lib/svc.sh self.sh modules/sb.sh modules/sb_openwrt.sh modules/system.sh modules/tcp.sh modules/ufw.sh menu/main.sh; do
    # shellcheck disable=SC1090,SC1091
    source "$ROOT_DIR/shell/src/$file"
done
PASS=0
FAIL=0
run_test() {
    local name="$1"; shift
    if ("$@"); then printf 'ok - %s\n' "$name"; ((PASS += 1));
    else printf 'not ok - %s\n' "$name" >&2; ((FAIL += 1)); fi
}

setup() {
    test_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$test_root"' EXIT
    PLATFORM="openwrt"
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
    log::info() { :; }; log::warn() { :; }; log::err() { :; }
    TMP_DIR="$test_root/tmp"
    STATE_DIR="$test_root/state"
    SB_BINARY_FILE="$test_root/bin/sing-box"
    SB_INIT_FILE="$test_root/init.d/sing-box"
    SB_UCI_FILE="$test_root/etc/sing-box-uci"
    SB_CONFIG_DIR="$test_root/etc/sing-box"
    SB_CONFIG_FILE="$SB_CONFIG_DIR/config.json"
    mkdir -p "$TMP_DIR" "$test_root/bin" "$test_root/init.d" "$SB_CONFIG_DIR"
    PATH="$test_root/bin:$PATH"
    sys::has_cmd() {
        if [[ "$1" == sing-box ]]; then [[ -x "$SB_BINARY_FILE" ]]; else command -v "$1" >/dev/null 2>&1; fi
    }
    export TEST_CALLS="$test_root/calls"
    : > "$TEST_CALLS"
    test_arch="x86_64"
    apk() {
        case "$*" in
            --print-arch) printf '%s\n' "$test_arch" ;;
            'info --exists sing-box') return 1 ;;
            *) printf '%s\n' "$*" >> "$TEST_CALLS" ;;
        esac
    }
    sys::has_procd() { return 0; }
    uci() {
        case "$*" in
            '-q get sing-box.main.enabled') echo 1 ;;
            '-q get sing-box.main.conffile') echo "$test_root/etc/sing-box/config.json" ;;
            *) return 1 ;;
        esac
    }
}

test_detection() {
    setup
    ui::confirm() { return 1; }
    local id version expected
    while read -r id version expected; do
        printf 'ID=%s\nVERSION_ID=%s\n' "$id" "$version" > "$test_root/os-release"
        if [[ "$expected" == yes ]]; then sys::require_supported "$test_root/os-release" || return 1
        else ! sys::require_supported "$test_root/os-release" || return 1; fi
    done <<'SYSTEMS'
openwrt 25.12.0 yes
openwrt 26.01.0 yes
openwrt 24.10.0 no
openwrt SNAPSHOT no
debian 12 yes
ubuntu 24.04 yes
alpine 3.22 no
SYSTEMS
    printf 'ID=openwrt\nVERSION_ID=25.12.0\n' > "$test_root/os-release"
    sys::has_cmd() { return 1; }
    ! sys::require_supported "$test_root/os-release"
}

test_paths() {
    PLATFORM="openwrt"
    runtime::set_platform_paths
    [[ "$STATE_DIR" == /etc/sm && "$INSTALL_PATH" == /usr/bin/sm.sh &&
       "$CONFIG_URL_FILE" == /etc/sm/default_url && "$UPDATE_CHANNEL_FILE" == /etc/sm/update_channel ]]
}

test_dependencies() {
    setup
    _DEPS_CHECKED=0
    sys::has_cmd() { [[ "$1" != curl && "$1" != install && "$1" != cmp && "$1" != realpath && "$1" != timeout ]]; }
    pkg::ensure_deps || return 1
    [[ "$(cat "$TEST_CALLS")" == $'info --exists ca-bundle\nupdate\nadd curl coreutils-install diffutils coreutils-realpath coreutils-timeout' ]]
}

test_lock_bootstrap() {
    setup
    local has_flock=0
    sys::has_cmd() { [[ "$has_flock" -eq 1 ]]; }
    pkg::install() { printf '%s\n' "$*" >> "$TEST_CALLS"; has_flock=1; }
    pkg::ensure_lock_dep || return 1
    [[ "$(cat "$TEST_CALLS")" == $'update\nflock' ]]
}

test_disabled_operations() {
    setup
    local operation
    for operation in system::full_upgrade tcp::run ufw::install ufw::enable ufw::disable ufw::reload ufw::uninstall ufw::allow pkg::full_upgrade pkg::purge pkg::autoremove pkg::clean; do
        ! "$operation" || return 1
    done
    [[ ! -s "$TEST_CALLS" ]]
}

test_menu() {
    setup
    sys::uptime() { echo uptime; }; sb::version() { echo version; }; sb::status() { echo stopped; }
    ufw::status_text() { echo forbidden >> "$TEST_CALLS"; }
    system::full_upgrade() { echo forbidden >> "$TEST_CALLS"; }
    menu::ufw() { echo forbidden >> "$TEST_CALLS"; }
    tcp::run() { echo forbidden >> "$TEST_CALLS"; }
    ui::clear() { :; }; ui::divider() { :; }; ui::pause() { :; }
    local index=0 output
    local choices=(4 5 6 0)
    ui::prompt() { printf -v "$2" '%s' "${choices[$index]}"; ((index += 1)); }
    output=$(menu::main) || return 1
    [[ "$output" != *'UFW'* && "$output" != *'full-upgrade'* && "$output" != *'TCP'* && ! -s "$TEST_CALLS" ]]
}

test_procd() {
    setup
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$TEST_CALLS"\n' > "$SB_INIT_FILE"
    chmod +x "$SB_INIT_FILE"
    svc::start sing-box && svc::stop sing-box && svc::restart sing-box && svc::enable sing-box && svc::disable sing-box || return 1
    [[ "$(cat "$TEST_CALLS")" == $'start\nstop\nrestart\nenable\ndisable' ]] || return 1
    timeout() { shift; "$@"; }
    ubus() { printf '%s\n' '{"sing-box":{"instances":{"main":{"running":true}}}}'; }
    svc::is_active sing-box || return 1
    ubus() { printf '%s\n' '{"sing-box":{"instances":{"main":{"running":false}}}}'; }
    ! svc::is_active sing-box || return 1
    ubus() { echo '{}'; }
    ! svc::is_active sing-box || return 1
    logread() { printf '%s\n' "$*" >> "$TEST_CALLS"; }
    svc::logs sing-box
    [[ "$(tail -n 1 "$TEST_CALLS")" == '-f -e sing-box' ]]
}

write_core() {
    local target="$1" version="$2"
    mkdir -p "$(dirname "$target")"
    printf '#!/bin/bash\ncase "$1" in\nversion) echo "sing-box version %s" ;;\ncheck) ! grep -q incompatible "$3" ;;\nesac\n' "$version" > "$target"
    chmod +x "$target"
}

make_release() {
    local version="$1" asset digest
    asset=$(printf 'sing-box_%s_openwrt_%s.apk' "$version" "$test_arch")
    printf '%s\n' "$version" > "$test_root/$version.apk"
    digest=$(sha256sum "$test_root/$version.apk" | awk '{print $1}')
    jq -n --arg tag "v$version" --arg name "$asset" --arg digest "sha256:$digest" \
        --arg url "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" \
        '{tag_name:$tag,draft:false,prerelease:false,assets:[{name:$name,browser_download_url:$url,digest:$digest}]}' > "$test_root/$version.json"
}

prepare_release() {
    make_release 1.14.3; make_release 1.13.0
    test_installed=0; test_active=0; test_restart_fail=0; test_package_fail=0
    net::fetch() {
        if [[ "$1" == */tags/v1.13.0 ]]; then cat "$test_root/1.13.0.json"
        else cat "$test_root/1.14.3.json"; fi
    }
    net::download() {
        echo download >> "$TEST_CALLS"
        if [[ "$1" == */v1.13.0/* ]]; then cp "$test_root/1.13.0.apk" "$2"
        else cp "$test_root/1.14.3.apk" "$2"; fi
    }
    apk() {
        case "$*" in
            --print-arch) printf '%s\n' "$test_arch" ;;
            'info --exists sing-box') [[ "$test_installed" -eq 1 ]] ;;
            'extract '*)
                echo extract >> "$TEST_CALLS"
                [[ ! -e "$4/usr/bin/sing-box" ]] || return 1
                write_core "$4/usr/bin/sing-box" 1.14.3 ;;
            'add --allow-untrusted '*)
                echo "install $(cat "$3")" >> "$TEST_CALLS"
                [[ "$test_package_fail" -eq 0 ]] || return 1
                write_core "$SB_BINARY_FILE" "$(cat "$3")"
                printf '#!/bin/sh\nexit 0\n' > "$SB_INIT_FILE"
                chmod +x "$SB_INIT_FILE"
                [[ -e "$SB_CONFIG_FILE" ]] || echo package-default > "$SB_CONFIG_FILE"
                [[ -e "$SB_UCI_FILE" ]] || echo package-uci > "$SB_UCI_FILE"
                test_installed=1 ;;
            'info --installed --depends sing-box')
                printf 'sing-box depends on:\nca-bundle\nfirewall4\nkmod-tun\n' ;;
            'del sing-box')
                echo del >> "$TEST_CALLS"
                rm -f -- "$SB_BINARY_FILE" "$SB_INIT_FILE" "$SB_CONFIG_FILE" "$SB_UCI_FILE"
                test_installed=0 ;;
            *) printf '%s\n' "$*" >> "$TEST_CALLS" ;;
        esac
    }
    svc::is_active() { [[ "$test_active" -eq 1 ]]; }
    svc::wait_active() { svc::is_active "$1"; }
    svc::start() { echo start >> "$TEST_CALLS"; test_active=1; }
    svc::stop() { echo stop >> "$TEST_CALLS"; test_active=0; }
    svc::enable() { echo enable >> "$TEST_CALLS"; }
    svc::disable() { echo disable >> "$TEST_CALLS"; }
    svc::restart() { echo restart >> "$TEST_CALLS"; [[ "$test_restart_fail" -eq 0 ]]; }
}

prepare_existing() {
    test_installed=1
    write_core "$SB_BINARY_FILE" 1.13.0
    printf '#!/bin/sh\nexit 0\n' > "$SB_INIT_FILE"
    chmod +x "$SB_INIT_FILE"
    echo '{"existing":true}' > "$SB_CONFIG_FILE"
    echo existing-uci > "$SB_UCI_FILE"
}

test_architectures() {
    setup
    net::download() { cp "$test_root/1.14.3.apk" "$2"; }
    for test_arch in x86_64 aarch64_cortex-a53 arm_cortex-a7_neon-vfpv4 mipsel_24kc; do
        make_release 1.14.3
        sb::download_openwrt_apk "$(cat "$test_root/1.14.3.json")" 1.14.3 "$test_root/download.apk" || return 1
    done
    test_arch='../invalid'
    ! sb::download_openwrt_apk '{}' 1.14.3 "$test_root/download.apk"
}

test_install() {
    setup; prepare_release
    sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.14.3 && "$test_installed" -eq 1 &&
       "$(cat "$TEST_CALLS")" == $'download\nextract\ninstall 1.14.3\nenable\nstart' ]] || return 1
    jq -e '.inbounds | length == 0' "$SB_CONFIG_FILE" >/dev/null
}

test_update() {
    setup; prepare_release; prepare_existing
    test_active=1
    sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.14.3 && "$(cat "$SB_CONFIG_FILE")" == '{"existing":true}' &&
       "$(cat "$SB_UCI_FILE")" == existing-uci &&
       "$(cat "$TEST_CALLS")" == $'download\nextract\ninstall 1.14.3\nrestart' ]]
}

test_stopped_update() {
    setup; prepare_release; prepare_existing
    sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.14.3 && "$(cat "$TEST_CALLS")" == $'download\nextract\ninstall 1.14.3' ]]
}

test_rollback() {
    setup; prepare_release; prepare_existing
    test_active=1; test_restart_fail=1
    ! sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.13.0 && "$(cat "$SB_CONFIG_FILE")" == '{"existing":true}' &&
       "$(cat "$TEST_CALLS")" == $'download\nextract\ninstall 1.14.3\nrestart\nstop\ndownload\ninstall 1.13.0\nstart' ]]
}

test_package_failure() {
    setup; prepare_release; prepare_existing
    test_package_fail=1
    ! sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.13.0 && "$(cat "$SB_CONFIG_FILE")" == '{"existing":true}' ]] || return 1
    test_package_fail=0
    sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.14.3 ]]
}

test_bad_download() {
    setup; prepare_release; prepare_existing
    echo corrupt > "$test_root/1.14.3.apk"
    ! sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.13.0 && "$(cat "$TEST_CALLS")" == download ]]
}

test_incompatible_config() {
    setup; prepare_release; prepare_existing
    echo incompatible > "$SB_CONFIG_FILE"
    ! sb::install_openwrt || return 1
    [[ "$(sb::version)" == 1.13.0 && "$(cat "$TEST_CALLS")" == $'download\nextract' ]]
}

test_invalid_release() {
    setup; prepare_release
    local expression
    for expression in '.prerelease=true' '.draft=true' '.tag_name="v1.14.3-beta.1"' '.assets=[]' '.assets[0].digest=null' '.assets[0].browser_download_url="https://example.com/core"'; do
        jq "$expression" "$test_root/1.14.3.json" > "$test_root/invalid.json"
        net::fetch() { cat "$test_root/invalid.json"; }
        ! sb::install_openwrt || return 1
        [[ ! -e "$SB_BINARY_FILE" && ! -s "$TEST_CALLS" ]] || return 1
    done
}

test_existing_conflicts() {
    setup; prepare_release
    echo unmanaged > "$SB_INIT_FILE"
    ! sb::install_openwrt || return 1
    [[ "$(cat "$SB_INIT_FILE")" == unmanaged && ! -s "$TEST_CALLS" ]]
}

test_current_version() {
    setup; prepare_release; prepare_existing
    write_core "$SB_BINARY_FILE" 1.14.3
    sb::install_openwrt || return 1
    write_core "$SB_BINARY_FILE" 1.15.0
    sb::install_openwrt || return 1
    [[ ! -s "$TEST_CALLS" ]]
}

test_uci_config() {
    setup
    uci() { printf '%s\n' "$test_root/custom/config.json"; }
    sb::sync_openwrt_config_path || return 1
    [[ "$SB_CONFIG_FILE" == "$test_root/custom/config.json" && "$SB_CONFIG_DIR" == "$test_root/custom" ]] || return 1
    uci() { return 1; }
    sb::sync_openwrt_config_path || return 1
    [[ "$SB_CONFIG_FILE" == /etc/sing-box/config.json && "$SB_CONFIG_DIR" == /etc/sing-box ]] || return 1
    uci() { echo relative/config.json; }
    ! sb::sync_openwrt_config_path
}

test_uninstall() {
    setup; prepare_release; prepare_existing
    hash -p "$SB_BINARY_FILE" sing-box
    ui::confirm() { [[ "$1" != '是否同时删除配置文件 '* ]]; }
    sb::uninstall_openwrt || return 1
    [[ "$test_installed" -eq 0 && ! -e "$SB_BINARY_FILE" && ! -e "$SB_INIT_FILE" &&
       "$(cat "$SB_CONFIG_FILE")" == '{"existing":true}' && "$(cat "$SB_UCI_FILE")" == existing-uci &&
       "$(cat "$TEST_CALLS")" == $'stop\ndisable\nadd ca-bundle firewall4 kmod-tun\ndel' ]] || return 1
    ! hash -t sing-box >/dev/null 2>&1
}

test_self_uninstall() {
    setup
    INSTALL_PATH="$test_root/bin/sm.sh"
    mkdir -p "$STATE_DIR"
    touch "$INSTALL_PATH" "$STATE_DIR/update_channel"
    ufw::is_installed() { echo forbidden >> "$TEST_CALLS"; return 0; }
    ui::confirm() { return 0; }
    (self::uninstall) >/dev/null || return 1
    [[ ! -e "$INSTALL_PATH" && ! -e "$STATE_DIR" && ! -s "$TEST_CALLS" ]]
}

run_test 'OpenWrt version and APK detection' test_detection
run_test 'OpenWrt persistent paths' test_paths
run_test 'exact OpenWrt APK architecture assets' test_architectures
run_test 'minimal APK dependencies despite BusyBox wget' test_dependencies
run_test 'flock bootstraps before runtime lock' test_lock_bootstrap
run_test 'system/firewall/network operations are blocked' test_disabled_operations
run_test 'hidden menu numbers cannot call disabled operations' test_menu
run_test 'native procd actions, ubus status and logread' test_procd
run_test 'verified official APK installs through package manager' test_install
run_test 'running package update preserves JSON/UCI and restarts' test_update
run_test 'stopped package update remains stopped' test_stopped_update
run_test 'failed restart restores previous official APK' test_rollback
run_test 'APK install failure preserves core and permits retry' test_package_failure
run_test 'bad checksum never invokes APK installation' test_bad_download
run_test 'incompatible config rejects APK before installation' test_incompatible_config
run_test 'preview/draft/missing/untrusted APK assets are rejected' test_invalid_release
run_test 'foreign non-APK service is not overwritten' test_existing_conflicts
run_test 'equal or newer core is not downloaded or downgraded' test_current_version
run_test 'UCI custom config path is respected and validated' test_uci_config
run_test 'native uninstall preserves configs and shared dependencies' test_uninstall
run_test 'self uninstall uses platform state and never inspects UFW' test_self_uninstall
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
