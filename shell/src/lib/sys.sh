# ==============================================================================
# sys:: 系统探测与基本环境
# ==============================================================================

sys::has_cmd() { command -v "$1" &>/dev/null; }

sys::has_systemd() {
    sys::has_cmd systemctl && [[ -d /run/systemd/system ]] &&
        [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

sys::require_root() {
    [[ $EUID -ne 0 ]] && { log::err "请使用 root 用户运行此脚本 (sudo -i)"; exit 1; }
}

sys::require_debian() {
    if [[ ! -f /etc/os-release ]]; then
        log::err "无法检测系统版本，仅支持 Debian/Ubuntu 标准发行版。"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
        log::warn "本脚本专为 Debian/Ubuntu 设计，检测到当前系统为: $ID"
        ui::confirm "是否强制继续?" || exit 1
    fi
}

sys::uptime() {
    sys::has_cmd uptime && uptime -p 2>/dev/null | sed 's/up //' || echo "N/A"
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
