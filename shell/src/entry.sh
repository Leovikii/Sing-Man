# ==============================================================================
# 入口
# ==============================================================================

main() {
    sys::require_root
    sys::require_debian
    runtime::init_tmp || exit 1
    pkg::ensure_deps || { log::err "依赖准备失败，无法继续。"; exit 1; }
    self::install_shortcut "$@" || { log::err "管理脚本自安装失败，无法继续。"; exit 1; }
    menu::main "$@"
}

main "$@"
