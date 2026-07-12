# ==============================================================================
# 全局常量、临时目录、信号陷阱
# ==============================================================================

SCRIPT_NAME="sm.sh"
SCRIPT_VERSION="3.2.7"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
SCRIPT_UPDATE_URL="https://api.github.com/repos/Leovikii/Sing-Man/releases"

CONFIG_URL_FILE="/var/lib/sm/default_url"
CONFIG_DATE_FILE="/var/lib/sm/config_last_update"
TCPX_URL="https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"

# 用 $'...' 在赋值时就把 \033 解析成真 ESC 字节，
# 让 read -p / printf "%s" 等不解析转义的场景也能正常带色
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
PLAIN=$'\033[0m'

TMP_DIR=""
_DEPS_CHECKED=0

runtime::init_tmp() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && return 0

    TMP_DIR=$(mktemp -d /tmp/sm_manager.XXXXXXXX) || {
        log::err "无法创建安全临时目录。"
        return 1
    }
    if ! chmod 0700 "$TMP_DIR"; then
        rm -rf -- "$TMP_DIR"
        TMP_DIR=""
        log::err "无法设置临时目录权限。"
        return 1
    fi
}

cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT TERM HUP
