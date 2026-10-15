# ==============================================================================
# svc:: systemd / OpenWrt procd 服务封装
# ==============================================================================

svc::_require_systemd() {
    if ! sys::has_systemd; then
        log::err "当前环境未运行 systemd，无法管理系统服务。"
        return 1
    fi
}

svc::_procd() {
    local name="$1" action="$2"
    if [[ "$name" != "sing-box" || ! -x "$SB_INIT_FILE" ]] || ! sys::has_procd; then
        log::err "未找到可用的 OpenWrt procd / Sing-box init 服务。"
        return 1
    fi
    case "$action" in
        start|restart|enable)
            if [[ "$(uci -q get sing-box.main.enabled)" != 1 ]]; then
                uci set sing-box.main.enabled=1 && uci commit sing-box || return 1
            fi ;;
    esac
    timeout "$SYSTEMCTL_TIMEOUT" "$SB_INIT_FILE" "$action"
}

svc::_action() {
    local name="$1" action="$2"
    if sys::is_openwrt; then
        svc::_procd "$name" "$action"
    else
        svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl "$action" "$name"
    fi
}

svc::is_active() {
    if sys::is_openwrt; then
        [[ "$1" == "sing-box" ]] || return 1
        timeout "$SYSTEMCTL_TIMEOUT" ubus call service list '{"name":"sing-box"}' 2>/dev/null |
            jq -e '."sing-box".instances // {} | any(.[]; .running == true)' >/dev/null 2>&1
    else
        sys::has_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl is-active --quiet "$1"
    fi
}
svc::start()     { svc::_action "$1" start; }
svc::stop()      { svc::_action "$1" stop 2>/dev/null; }
svc::restart()   { svc::_action "$1" restart; }
svc::enable()    { svc::_action "$1" enable >/dev/null 2>&1; }
svc::disable()   { svc::_action "$1" disable 2>/dev/null; }

svc::wait_active() {
    local attempts=0
    while (( attempts < 5 )); do
        if svc::is_active "$1"; then
            # procd 异步启动；避免将启动后立即崩溃的进程误报为成功。
            if sys::is_openwrt; then sleep 1; fi
            svc::is_active "$1" && return 0
        fi
        ((attempts += 1))
        sleep 1
    done
    return 1
}

svc::log_hint() {
    if sys::is_openwrt; then printf 'logread -e sing-box'; else printf 'journalctl -u sing-box'; fi
}

svc::logs()      {
    if ! sys::is_openwrt; then svc::_require_systemd || return 1; fi
    trap - INT
    if sys::is_openwrt; then logread -f -e "$1"; else journalctl -u "$1" -f -o cat; fi
    trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT TERM HUP
}

svc::ensure_running() {
    local name="$1"
    local ok_msg="${2:-$name 已启动}"
    local fail_msg="${3:-$name 启动失败，请检查 $(svc::log_hint)}"
    if ! svc::enable "$name"; then
        log::warn "无法设置 $name 开机启动。"
        return 1
    fi
    if ! svc::start "$name"; then
        log::warn "$fail_msg"
        return 1
    fi
    if svc::wait_active "$name"; then
        log::info "$ok_msg"
        return 0
    else
        log::warn "$fail_msg"
        return 1
    fi
}
