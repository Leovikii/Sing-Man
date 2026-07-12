# ==============================================================================
# 全局常量、临时目录、信号陷阱
# ==============================================================================

SCRIPT_NAME="sm.sh"
SCRIPT_VERSION="3.2.7"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
SCRIPT_UPDATE_URL="https://api.github.com/repos/Leovikii/Sing-Man/releases"
SAGERNET_GPG_FINGERPRINT="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"

CONFIG_URL_FILE="/var/lib/sm/default_url"
CONFIG_DATE_FILE="/var/lib/sm/config_last_update"
UPDATE_CHANNEL_FILE="/var/lib/sm/update_channel"
SB_CONFIG_DIR="/etc/sing-box"
SB_CONFIG_FILE="$SB_CONFIG_DIR/config.json"
TCPX_URL="https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"
LOCK_FILE="/run/lock/sm-manager.lock"
SYSTEMCTL_TIMEOUT=30
APT_LOCK_TIMEOUT=60
APT_NETWORK_TIMEOUT=30

# 用 $'...' 在赋值时就把 \033 解析成真 ESC 字节，
# 让 read -p / printf "%s" 等不解析转义的场景也能正常带色
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
PLAIN=$'\033[0m'

TMP_DIR=""
LOCK_HELD=0
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

runtime::acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" || {
        log::err "无法创建运行锁目录。"
        return 1
    }

    if ! command -v flock >/dev/null 2>&1; then
        log::err "系统缺少 flock 命令，无法安全防止多实例并发运行。"
        return 1
    fi
    exec 9>"$LOCK_FILE" || return 1
    if ! flock -n 9; then
        log::err "检测到另一个管理脚本实例正在运行，请稍后重试。"
        return 1
    fi
    LOCK_HELD=1
}

cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    if [[ "${LOCK_HELD:-0}" -eq 1 ]]; then
        exec 9>&-
        LOCK_HELD=0
    fi
    return 0
}
trap cleanup EXIT
trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT TERM HUP
