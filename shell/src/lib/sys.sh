# ==============================================================================
# sys:: 系统探测与基本环境
# ==============================================================================

sys::has_cmd() { command -v "$1" &>/dev/null; }

sys::has_systemd() {
    sys::has_cmd systemctl && [[ -d /run/systemd/system ]] &&
        [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

sys::has_procd() { [[ -r /etc/rc.common && -x /sbin/procd ]] && sys::has_cmd ubus; }

sys::require_root() {
    [[ $EUID -ne 0 ]] && { log::err "请使用 root 用户运行此脚本 (sudo -i)"; exit 1; }
}

sys::is_openwrt() { [[ "${PLATFORM:-}" == "openwrt" ]]; }

sys::require_system_tools() {
    if sys::is_openwrt; then
        log::err "OpenWrt 仅支持 Sing-box 核心、配置、服务及管理脚本操作。"
        return 1
    fi
}

sys::require_supported() {
    local release_file="${1:-/etc/os-release}"
    local ID="" ID_LIKE="" VERSION_ID=""
    if [[ ! -r "$release_file" ]]; then
        log::err "无法检测系统版本，仅支持 Debian/Ubuntu 和 OpenWrt 25+ (APK)。"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$release_file"
    PLATFORM=""
    if [[ "$ID" == "openwrt" ]]; then
        if [[ ! "$VERSION_ID" =~ ^([0-9]{2,})\. ]] ||
            (( 10#${BASH_REMATCH[1]:-0} < 25 )) || ! sys::has_cmd apk; then
            log::err "仅支持 OpenWrt 25 及之后的 APK 版本，不支持旧版、opkg 或无法识别版本的 SNAPSHOT。"
            return 1
        fi
        PLATFORM="openwrt"
        return 0
    fi
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
        log::warn "本脚本专为 Debian/Ubuntu 设计，检测到当前系统为: $ID"
        ui::confirm "是否按 Debian/Ubuntu 模式强制继续?" || return 1
    fi
    PLATFORM="debian"
}

sys::uptime() {
    if sys::is_openwrt; then
        awk '{d=int($1/86400); h=int($1/3600)%24; m=int($1/60)%60; printf "%d 天 %d 小时 %d 分钟\n", d,h,m}' /proc/uptime 2>/dev/null || echo "N/A"
    else
        sys::has_cmd uptime && uptime -p 2>/dev/null | sed 's/up //' || echo "N/A"
    fi
}

sys::reboot_if_needed() {
    [[ ! -f /var/run/reboot-required ]] && { log::info "升级完成，当前无需重启。"; return; }
    log::warn "系统提示需要重启以应用新内核 (常见于 root 提权漏洞修复)。"
    if ui::confirm "是否立即重启?"; then
        log::info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    else
        log::info "请稍后手动执行 reboot 完成内核切换。"
    fi
}
