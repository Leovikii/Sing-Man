# ==============================================================================
# menu::main - 主菜单
# ==============================================================================

menu::main() {
    while true; do
        local up sb_ver sb_st ufw_st
        up="$(sys::uptime)"
        sb_ver="$(sb::version)"
        sb_st="$(sb::status)"
        ufw_st="$(ufw::status_text)"

        ui::clear
        echo
        echo -e "${BLUE} ──────────────────────────────────────────────${PLAIN}"
        echo -e "  ${BLUE}❯${PLAIN} ${BLUE}Sing-box 管理脚本${PLAIN}  ${GREEN}v${SCRIPT_VERSION}${PLAIN}"
        echo -e "${BLUE} ──────────────────────────────────────────────${PLAIN}"
        echo -e "  ${BLUE}·${PLAIN} 系统运行时间  ${up}"
        echo -e "  ${BLUE}·${PLAIN} Sing-box 版本 ${BLUE}${sb_ver}${PLAIN}"
        echo -e "  ${BLUE}·${PLAIN} 运行状态      ${sb_st}"
        echo -e "  ${BLUE}·${PLAIN} UFW 状态      ${ufw_st}"
        ui::divider
        echo -e "  ${GREEN}1.${PLAIN} 安装 / 更新 Sing-box"
        echo -e "  ${GREEN}2.${PLAIN} 管理 Sing-box 服务 (启动/停止/日志)"
        echo -e "  ${GREEN}3.${PLAIN} 更新 Sing-box 配置文件"
        ui::divider
        echo -e "  ${GREEN}4.${PLAIN} 系统更新 (full-upgrade 修复内核漏洞)"
        echo -e "  ${GREEN}5.${PLAIN} UFW 防火墙管理"
        echo -e "  ${GREEN}6.${PLAIN} 系统 TCP 网络优化"
        ui::divider
        echo -e "  ${GREEN}7.${PLAIN} 检查并更新管理脚本"
        echo -e "  ${GREEN}8.${PLAIN} 卸载脚本 (可选卸载所有组件)"
        echo -e "  ${GREEN}0.${PLAIN}  退出"
        ui::divider
        echo -e "  ${BLUE}快捷指令${PLAIN}: 输入 ${GREEN}${SCRIPT_NAME}${PLAIN} 即可再次调出此菜单"
        echo
        local opt
        ui::prompt " 请输入选项 [0-9]: " opt
        case "$opt" in
            1)  sb::install; ui::pause ;;
            2)  if sb::require_installed; then menu::sb_service; else ui::pause; fi ;;
            3)  sb::require_installed && sb::update_config_interactive; ui::pause ;;
            4)  system::full_upgrade; ui::pause ;;
            5)  menu::ufw ;;
            6)  tcp::run; ui::pause ;;
            7)  self::check_update "$@" ;;
            8)  self::uninstall; ui::pause ;;
            0)  exit 0 ;;
            *)  log::err "无效选项，请重新输入"; ui::pause ;;
        esac
    done
}
