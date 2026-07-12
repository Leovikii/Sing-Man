# ==============================================================================
# svc:: systemd 服务封装
# ==============================================================================

svc::_require_systemd() {
    if ! sys::has_systemd; then
        log::err "当前环境未运行 systemd，无法管理系统服务。"
        return 1
    fi
}

svc::is_active() { sys::has_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl is-active --quiet "$1"; }
svc::start()     { svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl start "$1"; }
svc::stop()      { svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl stop "$1" 2>/dev/null; }
svc::restart()   { svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl restart "$1"; }
svc::enable()    { svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl enable "$1" >/dev/null 2>&1; }
svc::disable()   { svc::_require_systemd && timeout "$SYSTEMCTL_TIMEOUT" systemctl disable "$1" 2>/dev/null; }
svc::logs()      {
    svc::_require_systemd || return 1
    trap - INT
    journalctl -u "$1" -f -o cat
    trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT TERM HUP
}

svc::ensure_running() {
    local name="$1"
    local ok_msg="${2:-$name 已启动}"
    local fail_msg="${3:-$name 启动失败，请检查 journalctl -u $name}"
    if ! svc::enable "$name"; then
        log::warn "无法设置 $name 开机启动。"
        return 1
    fi
    if ! svc::start "$name"; then
        log::warn "$fail_msg"
        return 1
    fi
    if svc::is_active "$name"; then
        log::info "$ok_msg"
        return 0
    else
        log::warn "$fail_msg"
        return 1
    fi
}
