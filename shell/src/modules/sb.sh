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
        /etc/apt/sources.list.d/sagernet.list || {
        log::err "写入 Sing-box 软件源失败。"
        return 1
    }

    if ! pkg::update quiet; then
        log::warn "apt-get update 静默失败，尝试输出详细错误以供排查..."
        pkg::update || { log::err "系统软件源刷新失败，无法获取到最新版本列表。"; return 1; }
    fi
    if pkg::install sing-box; then
        svc::ensure_running sing-box "Sing-box 安装成功并已启动！"
    else
        log::err "安装失败，请检查网络连接。"
        return 1
    fi
}

sb::uninstall() {
    log::warn "即将卸载 Sing-box 及其软件源、密钥"
    ui::confirm "确认卸载?" || { log::info "取消卸载"; return; }

    svc::stop sing-box
    svc::disable sing-box
    if ! pkg::purge sing-box; then
        log::err "Sing-box 卸载失败，软件源和配置均未清理。"
        return 1
    fi

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
    if [[ -n "$CONFIG_URL_FILE" && -f "$CONFIG_URL_FILE" ]]; then
        chmod 0700 "$(dirname "$CONFIG_URL_FILE")" 2>/dev/null || return 1
        chmod 0600 "$CONFIG_URL_FILE" 2>/dev/null || return 1
        cat "$CONFIG_URL_FILE"
    fi
}

sb::set_default_url() {
    local state_dir
    state_dir=$(dirname "$CONFIG_URL_FILE")
    install -d -m 0700 "$state_dir" || return 1
    printf '%s\n' "$1" > "$CONFIG_URL_FILE" || return 1
    chmod 0600 "$CONFIG_URL_FILE"
}

sb::get_last_update_date() {
    if [[ -n "$CONFIG_DATE_FILE" && -f "$CONFIG_DATE_FILE" ]]; then
        chmod 0700 "$(dirname "$CONFIG_DATE_FILE")" 2>/dev/null || return 1
        chmod 0600 "$CONFIG_DATE_FILE" 2>/dev/null || return 1
        cat "$CONFIG_DATE_FILE"
    fi
}

sb::set_last_update_date() {
    local state_dir
    state_dir=$(dirname "$CONFIG_DATE_FILE")
    install -d -m 0700 "$state_dir" || return 1
    date "+%Y-%m-%d %H:%M:%S" > "$CONFIG_DATE_FILE" || return 1
    chmod 0600 "$CONFIG_DATE_FILE"
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
        echo -e "当前已保存默认配置链接（为保护敏感信息不显示具体内容）"
        ui::prompt "请输入配置下载链接 (直接回车保持默认): " new_url -e
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    if [[ ! "$new_url" =~ ^https://.+ ]]; then
        log::err "输入链接不合法，必须以 https:// 开头。"
        return 1
    fi

    local url="$new_url"
    mkdir -p "$TMP_DIR"
    local tmp_conf="$TMP_DIR/config.json"

    log::info "正在下载配置（链接已隐藏）..."
    if ! net::download "$url" "$tmp_conf"; then
        log::err "下载失败，请检查 URL 是否正确或网络是否畅通。"
        return 1
    fi

    if [[ ! -s "$tmp_conf" ]]; then
        log::err "下载的文件为空或不存在，下载失败。"
        return 1
    fi
    chmod 0600 "$tmp_conf" || {
        log::err "无法限制临时配置文件权限。"
        return 1
    }
    
    log::step "使用 Sing-box 内核进行配置语法语义校验..."
    if ! sing-box check -c "$tmp_conf"; then
        log::err "Sing-box 配置校验失败！请检查 JSON 内容是否合法。操作已取消。"
        return 1
    fi
    
    mkdir -p /etc/sing-box || {
        log::err "无法创建配置目录 /etc/sing-box。"
        return 1
    }
    local target_conf="/etc/sing-box/config.json"
    
    if [[ -f "$target_conf" ]]; then
        if cmp -s -- "$target_conf" "$tmp_conf"; then
            log::info "配置文件校验通过，但内容未发生变化。"
            chmod 0600 "$target_conf" || return 1
            if [[ "$new_url" != "$default_url" ]] && ! sb::set_default_url "$new_url"; then
                log::err "保存默认配置链接失败。"
                return 1
            fi
            sb::set_last_update_date || log::warn "配置已验证，但保存更新时间失败。"
            return 0
        fi
    fi

    # 在目标目录内暂存，保证替换动作在同一文件系统内完成。
    local staged_conf backup_conf had_old=0
    staged_conf=$(mktemp /etc/sing-box/.config.json.new.XXXXXXXX) || {
        log::err "无法创建配置暂存文件。"
        return 1
    }
    backup_conf="/etc/sing-box/.config.json.backup.$$"
    if ! install -m 0600 "$tmp_conf" "$staged_conf"; then
        rm -f -- "$staged_conf"
        log::err "无法写入配置暂存文件。"
        return 1
    fi

    if [[ -f "$target_conf" ]]; then
        had_old=1
        if ! cp -p -- "$target_conf" "$backup_conf"; then
            rm -f -- "$staged_conf"
            log::err "无法备份原配置，已取消更新。"
            return 1
        fi
    fi
    if ! mv -f -- "$staged_conf" "$target_conf"; then
        rm -f -- "$staged_conf" "$backup_conf"
        log::err "写入配置文件失败，原配置未被替换。"
        return 1
    fi
    if ui::confirm "是否重启 Sing-box 服务?"; then
        if svc::restart sing-box && svc::is_active sing-box; then
            rm -f -- "$backup_conf"
            log::info "服务已重启。"
        else
            log::err "服务重启失败，正在恢复旧配置。"
            if [[ "$had_old" -eq 1 && -f "$backup_conf" ]]; then
                if mv -f -- "$backup_conf" "$target_conf" && chmod 0600 "$target_conf"; then
                    if ! svc::restart sing-box >/dev/null 2>&1; then
                        log::err "旧配置已恢复，但服务仍无法启动，请检查 journalctl -u sing-box。"
                    fi
                else
                    log::err "自动恢复旧配置失败，请立即检查 $backup_conf。"
                fi
            else
                rm -f -- "$target_conf"
            fi
            return 1
        fi
    else
        rm -f -- "$backup_conf"
    fi

    if [[ "$new_url" != "$default_url" ]] && ! sb::set_default_url "$new_url"; then
        log::warn "配置已应用，但保存默认配置链接失败。"
    fi
    sb::set_last_update_date || log::warn "配置已应用，但保存更新时间失败。"
    log::info "配置文件校验通过并已应用！更新成功。"
}
