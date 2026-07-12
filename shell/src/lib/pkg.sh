# ==============================================================================
# pkg:: APT 软件包管理封装
# ==============================================================================

pkg::update() {
    if [[ "${1:-}" == "quiet" ]]; then
        apt-get update -y >/dev/null 2>&1
    else
        apt-get update -y
    fi
}

pkg::install()       { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
pkg::install_quiet() { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1; }
pkg::purge()         { DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"; }
pkg::autoremove()    { DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge "$@"; }
pkg::clean()         { apt-get clean; }

pkg::full_upgrade() {
    DEBIAN_FRONTEND=noninteractive apt-get "$@" -y full-upgrade
}

# 静默模式失败时回退到 verbose 模式重跑，让用户看到真实 apt 错误
pkg::ensure_deps() {
    [[ $_DEPS_CHECKED -eq 1 ]] && return 0

    local deps="curl wget jq tar ca-certificates gnupg"
    local missing=""
    for dep in $deps; do
        sys::has_cmd "$dep" || missing="$missing $dep"
    done

    if [[ -n "$missing" ]]; then
        log::info "正在安装必要依赖:$missing"
        if ! pkg::update quiet; then
            log::warn "apt-get update 静默失败，重试 verbose 模式以暴露错误..."
            pkg::update || { log::err "apt-get update 失败，请检查软件源/DNS/网络"; return 1; }
        fi
        if ! pkg::install_quiet $missing; then
            log::warn "依赖安装静默失败，重试 verbose 模式以暴露错误..."
            if ! pkg::install $missing; then
                log::err "依赖安装失败:$missing"
                log::info "常见原因: 软件源失效 / DNS 故障 / 签名过期 / 网络受限"
                return 1
            fi
        fi
    fi
    mkdir -p "$(dirname "$DEPS_FLAG")"
    touch "$DEPS_FLAG"
    _DEPS_CHECKED=1
}

pkg::add_gpg_key() {
    local url="$1" dest="$2" mode="${3:-}"
    if [[ "$mode" == "--dearmor" ]]; then
        net::fetch "$url" | gpg --dearmor --yes -o "$dest" || return 1
    else
        net::fetch "$url" > "$dest" || return 1
        [[ -s "$dest" ]] || { rm -f "$dest"; return 1; }
    fi
    chmod a+r "$dest"
}

pkg::write_repo() {
    local content="$1" dest="$2"
    echo "$content" > "$dest"
}
