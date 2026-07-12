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
}

self::get_update_channel() {
    local channel=""
    if [[ -f "$UPDATE_CHANNEL_FILE" ]]; then
        chmod 0700 "$(dirname "$UPDATE_CHANNEL_FILE")" 2>/dev/null || return 1
        chmod 0600 "$UPDATE_CHANNEL_FILE" 2>/dev/null || return 1
        channel=$(<"$UPDATE_CHANNEL_FILE")
    fi
    if [[ "$channel" == "stable" || "$channel" == "preview" ]]; then
        printf '%s\n' "$channel"
    elif version::is_prerelease "$SCRIPT_VERSION"; then
        printf 'preview\n'
    else
        printf 'stable\n'
    fi
}

self::set_update_channel() {
    local channel="$1" state_dir
    [[ "$channel" == "stable" || "$channel" == "preview" ]] || return 1
    state_dir=$(dirname "$UPDATE_CHANNEL_FILE")
    mkdir -p "$state_dir" || return 1
    chmod 0700 "$state_dir" || return 1
    printf '%s\n' "$channel" > "$UPDATE_CHANNEL_FILE" || return 1
    chmod 0600 "$UPDATE_CHANNEL_FILE"
}

self::configure_update_channel() {
    local current choice
    current=$(self::get_update_channel) || current="stable"
    echo -e "当前更新频道: ${GREEN}${current}${PLAIN}"
    echo "  [1] stable  - 仅接收正式版"
    echo "  [2] preview - 接收 beta / rc 等预发布版"
    ui::prompt "请选择更新频道 (1/2，回车保持当前): " choice
    case "$choice" in
        1) self::set_update_channel stable || return 1 ;;
        2) self::set_update_channel preview || return 1 ;;
        "") log::info "保持当前更新频道: $current"; return 0 ;;
        *) log::err "无效的更新频道选项。"; return 1 ;;
    esac
    log::info "更新频道已保存。"
}

self::check_update() {
    log::info "正在检查脚本更新..."

    local update_channel
    update_channel=$(self::get_update_channel) || update_channel="stable"
    log::info "当前更新频道: $update_channel"

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

    local stable_version="" beta_version="" remote_version prerelease
    while IFS=$'\t' read -r remote_version prerelease; do
        remote_version="${remote_version#v}"
        version::is_valid "$remote_version" || continue
        if [[ "$prerelease" == "true" ]]; then
            if [[ -z "$beta_version" ]] || version::gt "$remote_version" "$beta_version"; then
                beta_version="$remote_version"
            fi
        elif [[ -z "$stable_version" ]] || version::gt "$remote_version" "$stable_version"; then
            stable_version="$remote_version"
        fi
    done < <(echo "$api_resp" | jq -r '.[] | [.tag_name, (.prerelease | tostring)] | @tsv')

    [[ "$update_channel" == "stable" ]] && beta_version=""

    if [[ -z "$stable_version" && -z "$beta_version" ]]; then
        log::err "解析远程版本库失败，没有找到可用的 Release。"
        return 1
    fi

    local is_stable_newer=0
    if [[ -n "$stable_version" ]] && version::gt "$stable_version" "$SCRIPT_VERSION"; then
        is_stable_newer=1
    fi

    local is_beta_newer=0
    if [[ -n "$beta_version" ]] && version::gt "$beta_version" "$SCRIPT_VERSION"; then
        is_beta_newer=1
    fi

    if [[ "$is_stable_newer" == "0" && "$is_beta_newer" == "0" ]]; then
        log::info "当前已是最新版本 (v${SCRIPT_VERSION})，无需更新。"
        return 0
    fi

    local target_version=""
    
    if [[ "$is_stable_newer" == "1" && "$is_beta_newer" == "1" ]]; then
        local beta_gt_stable=0
        if version::gt "$beta_version" "$stable_version"; then
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
    local api_asset_sha
    api_asset_sha=$(echo "$api_resp" | jq -r --arg tag "v${target_version}" '
        .[] | select(.tag_name == $tag) | .assets[] |
        select(.name == "sm.sh") | (.digest // empty)' | sed 's/^sha256://')
    if [[ ! "$api_asset_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log::err "GitHub Release 未提供有效的脚本资产摘要，已取消更新。"
        return 1
    fi

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
    if [[ "${actual_sha,,}" != "${api_asset_sha,,}" ]]; then
        log::err "脚本与 GitHub Release 资产摘要不一致，已取消更新。"
        return 1
    fi
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
