# ==============================================================================
# tcp:: TCP 网络优化（运行外部脚本）
# ==============================================================================

tcp::run() {
    mkdir -p "$TMP_DIR"
    local tcp_local="$TMP_DIR/install_tcp.sh"

    log::info "正在下载 TCP 优化脚本..."
    if net::download "$TCPX_URL" "$tcp_local"; then
        chmod +x "$tcp_local"
        bash "$tcp_local"
    else
        log::err "TCP 脚本下载失败。"
        return 1
    fi
}
