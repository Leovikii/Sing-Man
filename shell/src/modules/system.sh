# ==============================================================================
# system:: 系统级操作（升级 / 内核）
# ==============================================================================

system::full_upgrade() {
    log::info "准备执行系统全量升级 (full-upgrade)..."
    
    log::step "[1/4] 更新软件源索引..."
    pkg::update || { log::err "apt-get update 失败，请检查软件源。"; return 1; }

    log::step "[2/4] 获取可更新的软件包列表..."
    local up_list
    up_list=$(apt list --upgradable 2>/dev/null | grep -v 'Listing...')
    if [[ -z "$up_list" ]]; then
        log::info "当前系统已是最新，没有需要升级的软件包。"
        return
    fi
    echo
    echo -e "${BLUE}=== 以下软件包将被升级 ===${PLAIN}"
    echo "$up_list" | head -n 20
    local up_count
    up_count=$(echo "$up_list" | wc -l)
    if [[ "$up_count" -gt 20 ]]; then
        echo -e "${YELLOW}... 等共计 ${up_count} 个软件包更新。${PLAIN}"
    fi
    echo
    
    log::warn "全量升级可能包含内核更新及依赖变化，建议升级后重启。"
    ui::confirm "确认继续升级上述软件包?" || { log::info "已取消。"; return; }

    local apt_opts=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

    log::step "[3/4] 执行 full-upgrade (包含内核升级)..."
    if ! pkg::full_upgrade "${apt_opts[@]}"; then
        log::err "full-upgrade 执行失败。"
        return 1
    fi

    log::step "[4/4] 清理无用依赖..."
    pkg::autoremove "${apt_opts[@]}"
    pkg::clean

    sys::reboot_if_needed
}
