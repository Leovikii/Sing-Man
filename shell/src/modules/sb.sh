# ==============================================================================
# sb:: Sing-box 业务模块
# ==============================================================================

sb::status() {
    if svc::is_active sing-box; then
        echo -e "${GREEN}运行中${PLAIN}"
    elif sys::has_cmd sing-box; then
        echo -e "${RED}已停止${PLAIN}"
    else
        echo -e "${YELLOW}未安装${PLAIN}"
    fi
}

sb::version() {
    if sys::has_cmd sing-box; then
        sing-box version 2>/dev/null | head -n 1 | awk '{print $3}'
    else
        echo "N/A"
    fi
}

sb::install() {
    log::info "准备安装/更新 Sing-box..."

    mkdir -p /etc/apt/keyrings
    pkg::add_gpg_key "https://sing-box.app/gpg.key" "/etc/apt/keyrings/sagernet.asc" || {
        log::err "Sing-box GPG 密钥下载失败。"; return 1; }

    pkg::write_repo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
        /etc/apt/sources.list.d/sagernet.list

    if ! pkg::update quiet; then
        log::warn "apt-get update 静默失败，尝试输出详细错误以供排查..."
        pkg::update || { log::err "系统软件源刷新失败，无法获取到最新版本列表。"; return 1; }
    fi
    if pkg::install sing-box; then
        svc::ensure_running sing-box "Sing-box 安装成功并已启动！"
    else
        log::err "安装失败，请检查网络连接。"
    fi
}

sb::uninstall() {
    log::warn "即将卸载 Sing-box 及其软件源、密钥"
    ui::confirm "确认卸载?" || { log::info "取消卸载"; return; }

    svc::stop sing-box
    svc::disable sing-box
    pkg::purge sing-box

    rm -f /etc/apt/sources.list.d/sagernet.list
    rm -f /etc/apt/keyrings/sagernet.asc

    # /etc/sing-box 内有用户拉下来或手写的 config.json 以及历史证书目录，
    # 默认保留并询问是否清理
    if [[ -d /etc/sing-box ]] && ui::confirm "是否同时删除配置目录 /etc/sing-box?"; then
        rm -rf /etc/sing-box
        log::info "/etc/sing-box 已删除"
    fi

    log::info "Sing-box 已卸载"
}

sb::require_installed() {
    if ! sys::has_cmd sing-box; then
        log::warn "未检测到 Sing-box 内核，配置与服务管理需要依赖它。"
        if ui::confirm "是否立即安装 Sing-box?"; then
            sb::install || return 1
        else
            return 1
        fi
    fi
    return 0
}

sb::get_default_url() {
    [[ -n "$CONFIG_URL_FILE" && -f "$CONFIG_URL_FILE" ]] && cat "$CONFIG_URL_FILE"
}

sb::set_default_url() {
    mkdir -p "$(dirname "$CONFIG_URL_FILE")"
    echo "$1" > "$CONFIG_URL_FILE"
}

sb::get_last_update_date() {
    [[ -n "$CONFIG_DATE_FILE" && -f "$CONFIG_DATE_FILE" ]] && cat "$CONFIG_DATE_FILE"
}

sb::set_last_update_date() {
    mkdir -p "$(dirname "$CONFIG_DATE_FILE")"
    date "+%Y-%m-%d %H:%M:%S" > "$CONFIG_DATE_FILE"
}

sb::update_config_interactive() {
    local default_url
    default_url=$(sb::get_default_url)
    local last_date
    last_date=$(sb::get_last_update_date)

    if [[ -n "$last_date" ]]; then
        echo -e "上次配置更新日期: ${YELLOW}${last_date}${PLAIN}"
    fi

    local new_url
    if [[ -z "$default_url" ]]; then
        ui::prompt "请输入配置下载链接: " new_url -e
        if [[ -z "$new_url" ]]; then
            log::err "链接不能为空，操作取消。"
            return 1
        fi
    else
        echo -e "当前默认配置链接: ${BLUE}${default_url}${PLAIN}"
        ui::prompt "请输入配置下载链接 (直接回车保持默认): " new_url -e
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    if [[ ! "$new_url" =~ ^https?://.+ ]]; then
        log::err "输入链接不合法，必须以 http:// 或 https:// 开头。"
        return 1
    fi

    local url="$new_url"
    mkdir -p "$TMP_DIR"
    local tmp_conf="$TMP_DIR/config.json"

    log::info "正在下载配置: $url"
    if ! net::download "$url" "$tmp_conf"; then
        log::err "下载失败，请检查 URL 是否正确或网络是否畅通。"
        return 1
    fi

    if [[ ! -s "$tmp_conf" ]]; then
        log::err "下载的文件为空或不存在，下载失败。"
        return 1
    fi
    
    log::step "使用 Sing-box 内核进行配置语法语义校验..."
    if ! sing-box check -c "$tmp_conf"; then
        log::err "Sing-box 配置校验失败！请检查 JSON 内容是否合法。操作已取消。"
        return 1
    fi
    
    mkdir -p /etc/sing-box
    local target_conf="/etc/sing-box/config.json"
    
    if [[ -f "$target_conf" ]]; then
        local old_md5 new_md5
        old_md5=$(md5sum "$target_conf" | awk '{print $1}')
        new_md5=$(md5sum "$tmp_conf" | awk '{print $1}')
        if [[ "$old_md5" == "$new_md5" ]]; then
            log::info "配置文件校验通过，但内容未发生变化。"
            [[ "$new_url" != "$default_url" ]] && sb::set_default_url "$new_url"
            sb::set_last_update_date
            return 0
        fi
    fi

    if ! mv "$tmp_conf" "$target_conf"; then
        log::err "写入配置文件失败，原配置未被替换。"
        return 1
    fi
    [[ "$new_url" != "$default_url" ]] && sb::set_default_url "$new_url"
    sb::set_last_update_date
    log::info "配置文件校验通过并已应用！更新成功。"
    if ui::confirm "是否重启 Sing-box 服务?"; then
        svc::restart sing-box && log::info "服务已重启。"
    fi
}
