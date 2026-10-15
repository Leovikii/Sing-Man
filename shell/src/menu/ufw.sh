# ==============================================================================
# menu::ufw - UFW 顶层菜单及子菜单
# ==============================================================================

menu::ufw_manage() {
    sys::require_system_tools || return 1
    while true; do
        ui::header "UFW 防火墙管理"
        echo -e " 当前状态: $(ufw::status_text)"
        echo
        echo -e "  ${GREEN}1.${PLAIN} 安装 UFW"
        echo -e "  ${GREEN}2.${PLAIN} 启用 UFW"
        echo -e "  ${GREEN}3.${PLAIN} 禁用 UFW"
        echo -e "  ${GREEN}4.${PLAIN} 重启 UFW"
        echo -e "  ${GREEN}5.${PLAIN} 卸载 UFW"
        echo -e "  ${GREEN}0.${PLAIN} 返回上级菜单"
        echo
        local opt
        ui::prompt " 请选择: " opt
        case "$opt" in
            1) ufw::install ;;
            2) ufw::enable ;;
            3) ufw::disable ;;
            4) ufw::reload ;;
            5) ufw::uninstall ;;
            0) return ;;
            *) log::err "无效选项" ;;
        esac
        [[ "$opt" != "0" ]] && ui::pause
    done
}

menu::ufw_rules() {
    sys::require_system_tools || return 1
    while true; do
        ui::header "UFW 规则管理"
        echo -e " 当前状态: $(ufw::status_text)"
        echo
        echo -e "  ${GREEN}1.${PLAIN} 添加规则"
        echo -e "  ${GREEN}2.${PLAIN} 删除规则"
        echo -e "  ${GREEN}3.${PLAIN} 查看当前规则"
        echo -e "  ${GREEN}0.${PLAIN} 返回上级菜单"
        echo
        local opt
        ui::prompt " 请选择: " opt
        case "$opt" in
            1) ufw::add_rule_interactive ;;
            2) ufw::delete_rule_interactive ;;
            3) ufw::list_numbered ;;
            0) return ;;
            *) log::err "无效选项" ;;
        esac
        [[ "$opt" != "0" ]] && ui::pause
    done
}

menu::ufw() {
    sys::require_system_tools || return 1
    while true; do
        ui::header "UFW 防火墙"
        echo -e " 当前状态: $(ufw::status_text)"
        echo
        echo -e "  ${GREEN}1.${PLAIN} UFW 服务管理 (安装/启停/卸载)"
        echo -e "  ${GREEN}2.${PLAIN} UFW 规则管理 (添加/删除/查看)"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo
        local opt
        ui::prompt " 请选择: " opt
        case "$opt" in
            1) menu::ufw_manage ;;
            2) menu::ufw_rules ;;
            0) return ;;
            *) log::err "无效选项"; ui::pause ;;
        esac
    done
}
