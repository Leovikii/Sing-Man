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
            uci -q export sing-box >/dev/null || return 1
            if ! svc::_uci_allows_start; then
                # UCI 关闭时手动启动仍需保持有效自启关闭。
                if [[ "$action" != enable ]]; then
                    timeout "$SYSTEMCTL_TIMEOUT" "$SB_INIT_FILE" disable || return 1
                fi
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
svc::enable()    { svc::_action "$1" enable; }
svc::disable()   { svc::_action "$1" disable; }

# 与 OpenWrt config_get_bool 的原生真值一致。
svc::_uci_allows_start() {
    case "$(uci -q get sing-box.main.enabled)" in 1|on|true|yes|enabled) return 0 ;; *) return 1 ;; esac
}

# 只查询，不改变服务或 UCI；未知/超时不能显示为已关闭。
svc::autostart_state() {
    local name="$1" state rc=0
    if sys::is_openwrt; then
        if [[ "$name" != sing-box || ! -x "$SB_INIT_FILE" ]]; then echo not-found; return 0; fi
        if ! sys::has_procd; then echo unavailable; return 1; fi
        timeout "$SYSTEMCTL_TIMEOUT" "$SB_INIT_FILE" enabled >/dev/null 2>&1 || rc=$?
        case "$rc" in
            0)
                uci -q export sing-box >/dev/null 2>&1 || { echo unknown; return 1; }
                if svc::_uci_allows_start; then echo enabled; else echo blocked; fi ;;
            1) echo disabled ;;
            *) echo unknown; return 1 ;;
        esac
    else
        if ! sys::has_systemd; then echo unavailable; return 1; fi
        state=$(timeout "$SYSTEMCTL_TIMEOUT" systemctl is-enabled "$name" 2>/dev/null) || rc=$?
        if [[ "$rc" -ne 0 && "$rc" -ne 1 && "$rc" -ne 4 ]]; then echo unknown; return 1; fi
        case "$state" in
            enabled|disabled|masked|masked-runtime|enabled-runtime|static|indirect|alias|generated|transient|linked|linked-runtime|not-found) echo "$state" ;;
            *) echo unknown; return 1 ;;
        esac
    fi
}

svc::set_autostart() {
    local name="$1" desired="$2" state
    state=$(svc::autostart_state "$name") || { log::err "无法查询开机自启状态。"; return 1; }
    case "$state" in
        masked*) log::err "服务已被 systemd 屏蔽，请先自行解除 mask。"; return 1 ;;
        not-found) log::err "未找到服务，请先安装核心。"; return 1 ;;
    esac
    case "$desired" in
        enabled) svc::enable "$name" || return 1 ;;
        disabled) svc::disable "$name" || return 1 ;;
        *) return 1 ;;
    esac
    state=$(svc::autostart_state "$name") || return 1
    if [[ "$state" != "$desired" ]]; then
        log::err "开机自启设置未生效（$state），请检查原生服务配置。"
        return 1
    fi
}

# 包维护脚本可能改变开机启动；升级成功、失败和回滚均恢复原选择。
svc::restore_autostart() {
    local name="$1" previous="$2" current
    current=$(svc::autostart_state "$name") || return 1
    [[ "$current" == "$previous" ]] && return 0
    case "$previous" in
        enabled|disabled) svc::set_autostart "$name" "$previous" ;;
        blocked)
            sys::is_openwrt || return 1
            uci set sing-box.main.enabled=0 && uci commit sing-box &&
                timeout "$SYSTEMCTL_TIMEOUT" "$SB_INIT_FILE" enable &&
                [[ "$(svc::autostart_state "$name")" == blocked ]] ;;
        *) log::err "包更新改变了特殊自启状态（$previous → $current），请手动恢复。"; return 1 ;;
    esac
}

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
    if ! svc::set_autostart "$name" enabled; then
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
