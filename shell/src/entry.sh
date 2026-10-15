# ==============================================================================
# 入口
# ==============================================================================

main() {
    sys::require_root
    sys::require_supported || exit 1
    runtime::set_platform_paths
    runtime::init_tmp || exit 1
    pkg::ensure_lock_dep || { log::err "运行锁依赖准备失败。"; exit 1; }
    runtime::acquire_lock || exit 1
    pkg::ensure_deps || { log::err "依赖准备失败，无法继续。"; exit 1; }
    self::install_shortcut "$@" || { log::err "管理脚本自安装失败，无法继续。"; exit 1; }
    menu::main "$@"
}

main "$@"
