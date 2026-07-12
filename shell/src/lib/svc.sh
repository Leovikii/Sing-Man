# ==============================================================================
# svc:: systemd 服务封装
# ==============================================================================

svc::is_active() { systemctl is-active --quiet "$1"; }
svc::start()     { systemctl start "$1"; }
svc::stop()      { systemctl stop "$1" 2>/dev/null; }
svc::restart()   { systemctl restart "$1"; }
svc::enable()    { systemctl enable "$1" >/dev/null 2>&1; }
svc::disable()   { systemctl disable "$1" 2>/dev/null; }
svc::logs()      {
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
