# ==============================================================================
# ufw:: UFW 防火墙业务模块
# ==============================================================================

ufw::is_installed() { sys::has_cmd ufw; }

# 加 timeout 防止某些 nf_tables 状态下 ufw status numbered 卡死
ufw::_status_numbered() {
    timeout 5 ufw status numbered 2>/dev/null
}

ufw::is_enabled() {
    sys::has_cmd ufw && LC_ALL=C timeout 5 ufw status verbose 2>/dev/null | head -n1 | grep -q "Status: active"
}

ufw::status_text() {
    if ! ufw::is_installed; then
        echo -e "${RED}未安装${PLAIN}"
    elif ufw::is_enabled; then
        echo -e "${GREEN}已启用${PLAIN}"
    else
        echo -e "${YELLOW}未启用${PLAIN}"
    fi
}

ufw::_require() {
    if ! ufw::is_installed; then
        log::err "UFW 未安装，请先安装 UFW"
        return 1
    fi
}

ufw::_detect_ssh_ports() {
    local detected=""

    # SSH_CONNECTION: 客户端IP 客户端端口 服务端IP 服务端端口
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local connection_port
        connection_port=$(awk '{print $4}' <<< "$SSH_CONNECTION")
        [[ "$connection_port" =~ ^[0-9]+$ ]] && detected+="$connection_port"$'\n'
    fi

    if sys::has_cmd sshd; then
        detected+=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}')
        detected+=$'\n'
    fi

    printf '%s' "$detected" | awk '$1 >= 1 && $1 <= 65535' | sort -nu
}

ufw::_get_ssh_ports() {
    local detected input port
    local ports=()
    detected=$(ufw::_detect_ssh_ports)
    if [[ -n "$detected" ]]; then
        printf '%s\n' "$detected"
        return 0
    fi

    log::warn "未能自动检测 SSH 监听端口；为避免启用防火墙后失联，必须手动指定。" >&2
    ui::prompt "请输入 SSH 端口（多个端口用空格分隔）: " input
    [[ -n "$input" ]] || return 1
    read -r -a ports <<< "$input"
    for port in "${ports[@]}"; do
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log::err "无效的 SSH 端口: $port" >&2
            return 1
        fi
        printf '%s\n' "$port"
    done | sort -nu
}

ufw::_rule_exists() {
    local spec="$1"
    LC_ALL=C timeout 5 ufw status 2>/dev/null |
        awk -v spec="$spec" '$1 == spec && $2 == "ALLOW" {found=1} END {exit !found}'
}

ufw::_rollback_added_rules() {
    local rules_name="$1" index
    local -n rules_ref="$rules_name"
    for (( index=${#rules_ref[@]}-1; index>=0; index-- )); do
        ufw --force delete allow "${rules_ref[$index]}" >/dev/null 2>&1 ||
            log::warn "自动回滚规则 ${rules_ref[$index]} 失败，请手动检查 UFW。"
    done
}

ufw::_ensure_allow() {
    local port="$1" proto="$2" comment="$3" added_name="$4"
    local spec="${port}/${proto}"
    local -n added_ref="$added_name"
    ufw::_rule_exists "$spec" && return 0
    if ufw::allow "$port" "$proto" "$comment"; then
        added_ref+=("$spec")
        return 0
    fi
    return 1
}

ufw::ensure_baseline_rules() {
    local ssh_ports port
    # 通过 nameref 传给 _ensure_allow / _rollback_added_rules。
    # shellcheck disable=SC2034
    local added_rules=()
    if ! ssh_ports=$(ufw::_get_ssh_ports) || [[ -z "$ssh_ports" ]]; then
        log::err "未取得有效 SSH 端口；为避免失联，不会启用 UFW。"
        return 1
    fi

    log::warn "确保放行检测到的 SSH 端口及 80/443 端口 (TCP/UDP、IPv4/IPv6 双栈)"
    log::info "检测到 SSH 端口: $(tr '\n' ' ' <<< "$ssh_ports" | sed 's/[[:space:]]*$//')"
    while IFS= read -r port; do
        if ! ufw::_ensure_allow "$port" tcp "SSH TCP" added_rules ||
           ! ufw::_ensure_allow "$port" udp "SSH UDP" added_rules; then
            ufw::_rollback_added_rules added_rules
            return 1
        fi
    done <<< "$ssh_ports"

    if ! ufw::_ensure_allow 80 tcp "HTTP TCP" added_rules ||
       ! ufw::_ensure_allow 80 udp "HTTP UDP" added_rules ||
       ! ufw::_ensure_allow 443 tcp "HTTPS TCP" added_rules ||
       ! ufw::_ensure_allow 443 udp "HTTPS UDP" added_rules; then
        ufw::_rollback_added_rules added_rules
        return 1
    fi
}

ufw::install() {
    if ufw::is_installed; then
        log::warn "UFW 已经安装，正在检查更新..."
        if ! pkg::update quiet; then
            log::err "软件源刷新失败，无法检查 UFW 更新。"
            return 1
        fi
        if apt list --upgradable 2>/dev/null | grep -q "^ufw/"; then
            log::info "发现 UFW 更新"
            if ui::confirm "是否更新 UFW?"; then
                if pkg::install_quiet ufw; then
                    log::info "UFW 更新完成"
                else
                    log::err "UFW 更新失败。"
                    return 1
                fi
            else
                log::info "跳过更新"
            fi
        else
            log::info "UFW 已是最新版本"
        fi
        ufw::ensure_baseline_rules
    fi

    log::info "正在安装 UFW..."
    if ! pkg::update quiet; then
        log::err "软件源刷新失败，无法安装 UFW。"
        return 1
    fi
    if ! pkg::install_quiet ufw; then
        log::err "UFW 安装失败"
        return 1
    fi

    log::info "UFW 安装成功"
    ufw::ensure_baseline_rules || return 1

    log::step "正在启用 UFW..."
    if echo "y" | ufw enable >/dev/null 2>&1; then
        log::info "UFW 已自动启用"
        return 0
    else
        log::err "UFW 启用失败"
        return 1
    fi
}

ufw::enable() {
    ufw::_require || return
    ufw::ensure_baseline_rules || return 1
    if echo "y" | ufw enable >/dev/null 2>&1; then
        log::info "UFW 已启用"
        return 0
    else
        log::err "UFW 启用失败"
        return 1
    fi
}

ufw::disable() {
    ufw::_require || return
    if ufw disable >/dev/null 2>&1; then
        log::info "UFW 已禁用"
        return 0
    else
        log::err "UFW 禁用失败"
        return 1
    fi
}

ufw::reload() {
    ufw::_require || return
    if ufw reload >/dev/null 2>&1; then
        log::info "UFW 已重启"
        return 0
    else
        log::err "UFW 重启失败"
        return 1
    fi
}

ufw::uninstall() {
    if ! ufw::is_installed; then
        log::warn "UFW 未安装"
        return
    fi
    log::warn "即将卸载 UFW 及其所有配置"
    ui::confirm "确认卸载?" || { log::info "取消卸载"; return; }

    ufw disable >/dev/null 2>&1
    if ! pkg::purge ufw >/dev/null 2>&1; then
        log::err "UFW 卸载失败，已保留现有配置。"
        return 1
    fi
    rm -rf /etc/ufw /lib/ufw /var/lib/ufw
    log::info "UFW 已完全卸载"
}

ufw::allow() {
    local port="$1" proto="$2" comment="${3:-Port ${1}/${2}}"
    if ufw allow "${port}/${proto}" comment "$comment" >/dev/null 2>&1; then
        log::info "已放行 ${port}/${proto} (IPv4/IPv6)"
    else
        log::err "添加规则失败: ${port}/${proto}"
        return 1
    fi
}

ufw::list_numbered() {
    ufw::_require || return
    ufw::_status_numbered
}

ufw::add_rule_interactive() {
    ufw::_require || return
    log::info "添加 UFW 规则 (示例: 2222/tcp 或 8080/udp)"
    log::info "规则会自动应用于 IPv4 和 IPv6 双栈"
    local input
    ui::prompt "请输入端口/协议 (如 2222/tcp): " input

    if [[ ! "$input" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
        log::err "格式错误，请使用 端口/协议 格式（输入: $input）"
        return 1
    fi
    local port="${BASH_REMATCH[1]}"
    local proto="${BASH_REMATCH[2]}"
    if (( port < 1 || port > 65535 )); then
        log::err "端口必须在 1-65535 范围内（输入: $port）"
        return 1
    fi
    local other="udp"
    [[ "$proto" == "udp" ]] && other="tcp"

    ufw::allow "$port" "$proto"
    if ui::confirm "是否同时放行 ${port}/${other}?"; then
        ufw::allow "$port" "$other"
    fi
}

ufw::delete_rule_interactive() {
    ufw::_require || return
    log::info "当前防火墙规则："
    ufw::_status_numbered

    if ! ufw::_status_numbered | grep -q "^\["; then
        log::warn "当前没有任何规则"
        return
    fi

    log::warn "仅在 IPv4/IPv6 规则内容严格一致且配对唯一时提供成对删除。"
    local rule_num
    ui::prompt "请输入要删除的规则编号 (0 取消): " rule_num
    if [[ ! "$rule_num" =~ ^[0-9]+$ ]] || [[ "$rule_num" == "0" ]]; then
        log::warn "取消删除"
        return
    fi

    local rules_raw rule_info
    rules_raw=$(ufw::_status_numbered)
    rule_info=$(echo "$rules_raw" | grep "^\[ *$rule_num\]" | sed 's/\x1b\[[0-9;]*m//g')
    if [[ -z "$rule_info" ]]; then
        log::err "无效的规则编号"
        return 1
    fi
    log::info "已选择规则: $rule_info"

    local selected_normalized selected_is_v6=0 line candidate_normalized candidate_is_v6 num
    local pair_candidates=() rules_to_delete=("$rule_num")
    [[ "$rule_info" == *"(v6)"* ]] && selected_is_v6=1
    selected_normalized=$(printf '%s\n' "$rule_info" |
        sed -E 's/^\[[[:space:]]*[0-9]+\][[:space:]]+//; s/[[:space:]]+\(v6\)//g; s/[[:space:]]+/ /g')
    while IFS= read -r line; do
        num=$(printf '%s\n' "$line" | sed -n 's/^\[ *\([0-9]\+\)\].*/\1/p')
        [[ -z "$num" || "$num" == "$rule_num" ]] && continue
        candidate_is_v6=0
        [[ "$line" == *"(v6)"* ]] && candidate_is_v6=1
        [[ "$candidate_is_v6" -eq "$selected_is_v6" ]] && continue
        candidate_normalized=$(printf '%s\n' "$line" |
            sed -E 's/^\[[[:space:]]*[0-9]+\][[:space:]]+//; s/[[:space:]]+\(v6\)//g; s/[[:space:]]+/ /g')
        [[ "$candidate_normalized" == "$selected_normalized" ]] && pair_candidates+=("$num")
    done < <(printf '%s\n' "$rules_raw" | sed 's/\x1b\[[0-9;]*m//g' | grep '^\[')

    if [[ ${#pair_candidates[@]} -eq 1 ]]; then
        if ui::confirm "检测到严格匹配的 IPv4/IPv6 对应规则 ${pair_candidates[0]}，是否一并删除?"; then
            rules_to_delete+=("${pair_candidates[0]}")
        fi
    elif [[ ${#pair_candidates[@]} -gt 1 ]]; then
        log::warn "检测到多个相似规则，无法安全判断配对，将只删除选中规则。"
    fi

    IFS=$'\n' read -r -d '' -a rules_to_delete < <(
        printf '%s\n' "${rules_to_delete[@]}" | sort -rn -u
        printf '\0'
    )
    log::warn "将删除规则编号: ${rules_to_delete[*]}"
    ui::confirm "确认删除?" || { log::warn "取消删除"; return; }

    for num in "${rules_to_delete[@]}"; do
        if echo "y" | ufw delete "$num" >/dev/null 2>&1; then
            log::info "已删除规则 $num"
        else
            log::err "删除规则 $num 失败"
            return 1
        fi
    done
    log::info "更新后的规则列表："
    ufw::_status_numbered
}
