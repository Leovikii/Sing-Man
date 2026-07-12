# ==============================================================================
# self:: 脚本自身的安装/更新/卸载/配置持久化
# ==============================================================================

self::install_shortcut() {
    [[ "$(realpath "$0")" == "$(realpath "$INSTALL_PATH" 2>/dev/null)" ]] && return 0
    log::info "首次运行，正在执行自安装..."
    if ! install -m 0755 "$0" "$INSTALL_PATH"; then
        log::err "安装管理脚本失败: $INSTALL_PATH"
        return 1
    fi
    log::info "快捷方式已安装: 输入 ${GREEN}${SCRIPT_NAME}${PLAIN} 即可随时启动"
    exec "$INSTALL_PATH" "$@"
    log::err "重新启动管理脚本失败: $INSTALL_PATH"
    return 1
}

self::check_update() {
    log::info "正在检查脚本更新..."

    local api_resp
    api_resp=$(net::fetch "$SCRIPT_UPDATE_URL")
    if [[ -z "$api_resp" ]]; then
        log::err "获取远程版本失败，请检查网络连接或 Github API 限制。"
        return 1
    fi

    if ! echo "$api_resp" | jq -e 'type == "array"' >/dev/null 2>&1; then
        local msg
        msg=$(echo "$api_resp" | jq -r '.message // empty')
        if [[ -n "$msg" ]]; then
            log::err "GitHub API 返回错误: $msg"
        else
            log::err "获取远程版本失败，API 返回了非预期的格式。"
        fi
        return 1
    fi

    local stable_version=""
    local beta_version=""
    
    stable_version=$(echo "$api_resp" | jq -r '[.[] | select(.prerelease == false)] | .[0].tag_name // empty' | sed 's/^v//')
    beta_version=$(echo "$api_resp" | jq -r '[.[] | select(.prerelease == true)] | .[0].tag_name // empty' | sed 's/^v//')

    if [[ -z "$stable_version" && -z "$beta_version" ]]; then
        log::err "解析远程版本库失败，没有找到可用的 Release。"
        return 1
    fi

    local is_stable_newer=0
    if [[ -n "$stable_version" ]] && dpkg --compare-versions "$stable_version" "gt" "$SCRIPT_VERSION"; then
        is_stable_newer=1
    fi

    local is_beta_newer=0
    if [[ -n "$beta_version" ]] && dpkg --compare-versions "$beta_version" "gt" "$SCRIPT_VERSION"; then
        is_beta_newer=1
    fi

    if [[ "$is_stable_newer" == "0" && "$is_beta_newer" == "0" ]]; then
        log::info "当前已是最新版本 (v${SCRIPT_VERSION})，无需更新。"
        return 0
    fi

    local target_version=""
    
    if [[ "$is_stable_newer" == "1" && "$is_beta_newer" == "1" ]]; then
        local beta_gt_stable=0
        if dpkg --compare-versions "$beta_version" "gt" "$stable_version"; then
            beta_gt_stable=1
        fi
        if [[ "$beta_gt_stable" == "1" ]]; then
            log::info "发现新版本！"
            echo -e "  [1] 正式版: ${GREEN}v${stable_version}${PLAIN}"
            echo -e "  [2] 测试版: ${YELLOW}v${beta_version}${PLAIN} (当前版本: v${SCRIPT_VERSION})"
            local choice
            read -p "请选择要更新的版本 (1/2/按回车取消): " choice
            case "$choice" in
                1) target_version="$stable_version" ;;
                2) target_version="$beta_version" ;;
                *) log::info "已取消更新。"; return 0 ;;
            esac
        else
            target_version="$stable_version"
            log::info "发现新正式版本: ${GREEN}v${target_version}${PLAIN} (当前版本: v${SCRIPT_VERSION})"
            ui::confirm "是否更新管理脚本?" || { log::info "已取消更新。"; return 0; }
        fi
    elif [[ "$is_stable_newer" == "1" ]]; then
        target_version="$stable_version"
        log::info "发现新正式版本: ${GREEN}v${target_version}${PLAIN} (当前版本: v${SCRIPT_VERSION})"
        ui::confirm "是否更新管理脚本?" || { log::info "已取消更新。"; return 0; }
    elif [[ "$is_beta_newer" == "1" ]]; then
        target_version="$beta_version"
        log::info "发现新测试版本: ${YELLOW}v${target_version}${PLAIN} (当前版本: v${SCRIPT_VERSION})"
        ui::confirm "是否更新到测试版?" || { log::info "已取消更新。"; return 0; }
    fi

    if [[ -z "$target_version" ]]; then
        return 0
    fi

    local download_url="https://github.com/Leovikii/Sing-Man/releases/download/v${target_version}/sm.sh"
    local checksum_url="${download_url}.sha256"

    mkdir -p "$TMP_DIR"
    log::info "正在下载新版脚本 v${target_version}..."
    local temp_script="$TMP_DIR/new_sm.sh"
    if ! net::download "$download_url" "$temp_script"; then
        log::err "下载新版本文件失败。"
        return 1
    fi

    if [[ ! -s "$temp_script" ]]; then
        log::err "下载的新版本文件为空，已取消更新。"
        return 1
    fi
    local checksum_file="$TMP_DIR/sm.sh.sha256"
    if ! net::download "$checksum_url" "$checksum_file"; then
        log::err "下载校验和文件失败，已取消更新。"
        return 1
    fi
    local expected_sha actual_sha
    expected_sha=$(awk '$2 == "sm.sh" || $2 == "*sm.sh" {print $1; exit}' "$checksum_file")
    if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log::err "发布校验和格式无效，已取消更新。"
        return 1
    fi
    actual_sha=$(sha256sum "$temp_script" | awk '{print $1}')
    if [[ "${actual_sha,,}" != "${expected_sha,,}" ]]; then
        log::err "新版本脚本 SHA-256 校验失败，已取消更新。"
        return 1
    fi
    if ! bash -n "$temp_script"; then
        log::err "下载的新版本未通过 Bash 语法检查，已取消更新。"
        return 1
    fi
    if ! grep -Fq "SCRIPT_VERSION=\"${target_version}\"" "$temp_script"; then
        log::err "下载文件中的版本号与目标版本不一致，已取消更新。"
        return 1
    fi

    local staged_script="${INSTALL_PATH}.new.$$"
    if ! install -m 0755 "$temp_script" "$staged_script"; then
        log::err "暂存新版本失败，当前版本未被修改。"
        return 1
    fi
    if ! mv -f "$staged_script" "$INSTALL_PATH"; then
        rm -f "$staged_script"
        log::err "替换管理脚本失败，当前版本未被修改。"
        return 1
    fi
    log::info "脚本更新成功！正在重新加载..."
    sleep 1
    exec "$INSTALL_PATH" "$@"
}

self::uninstall() {
    echo -e "\n${RED}⚠️  正在进行全面卸载向导${PLAIN}"
    log::info "脚本将逐项检查各组件是否已安装并询问是否一并卸载。"
    echo

    if sys::has_cmd sing-box; then
        if ui::confirm "检测到 ${BLUE}Sing-box${PLAIN}，是否卸载?"; then
            sb::uninstall
        else
            log::info "已保留 Sing-box"
        fi
        echo
    fi

    if ufw::is_installed; then
        if ui::confirm "检测到 ${BLUE}UFW${PLAIN}，是否卸载? (将丢失所有防火墙规则)"; then
            ufw::uninstall
        else
            log::info "已保留 UFW"
        fi
        echo
    fi

    echo -e "是否删除 ${BLUE}本管理脚本 ($SCRIPT_NAME)${PLAIN} 及缓存文件？"
    if ui::confirm "请输入"; then
        [[ -f "$INSTALL_PATH" ]] && rm -f "$INSTALL_PATH" && log::info "脚本文件已删除: $INSTALL_PATH"
        rm -rf /var/lib/sm
        echo -e "${GREEN}卸载完成。再见！${PLAIN}"
        exit 0
    else
        log::info "已保留管理脚本。"
    fi
}
