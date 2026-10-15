# ==============================================================================
# menu::sb_service - Sing-box 服务管理子菜单
# ==============================================================================

menu::sb_service() {
    if sys::is_openwrt; then sb::require_openwrt_package || return 1; fi
    while true; do
        ui::header "Sing-box 服务管理"
        echo -e " 当前状态: $(sb::status)"
        echo
        echo -e "  ${GREEN}1.${PLAIN} 启动服务"
        echo -e "  ${GREEN}2.${PLAIN} 停止服务"
        echo -e "  ${GREEN}3.${PLAIN} 重启服务"
        echo -e "  ${GREEN}4.${PLAIN} 查看实时日志 (Ctrl+C 退出整个脚本)"
        echo -e "  ${GREEN}5.${PLAIN} 卸载 Sing-box"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo
        local opt
        ui::prompt " 请选择: " opt
        case "$opt" in
            1) svc::start sing-box && svc::wait_active sing-box && log::info "已启动" || log::err "启动失败，请检查 $(svc::log_hint)。" ;;
            2) svc::stop sing-box && log::info "已停止" ;;
            3) svc::restart sing-box && svc::wait_active sing-box && log::info "已重启" || log::err "重启失败，请检查 $(svc::log_hint)。" ;;
            4) svc::logs sing-box ;;
            5) ui::confirm "确定要彻底卸载 Sing-box 吗?" && sb::uninstall ;;
            0) return ;;
            *) log::err "无效选项" ;;
        esac
        [[ "$opt" != "4" && "$opt" != "0" ]] && ui::pause
    done
}
