# ==============================================================================
# pkg:: APT 软件包管理封装
# ==============================================================================

pkg::_apt() {
    apt-get \
        -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" \
        -o "Acquire::http::Timeout=${APT_NETWORK_TIMEOUT}" \
        -o "Acquire::https::Timeout=${APT_NETWORK_TIMEOUT}" \
        -o "Acquire::Retries=2" \
        "$@"
}

pkg::_apt_noninteractive() {
    DEBIAN_FRONTEND=noninteractive pkg::_apt "$@"
}

pkg::update() {
    if [[ "${1:-}" == "quiet" ]]; then
        pkg::_apt update >/dev/null 2>&1
    else
        pkg::_apt update
    fi
}

pkg::install()       { pkg::_apt_noninteractive install -y "$@"; }
pkg::install_quiet() { pkg::_apt_noninteractive install -y "$@" >/dev/null 2>&1; }
pkg::purge()         { pkg::_apt_noninteractive purge -y "$@"; }
pkg::autoremove()    { pkg::_apt_noninteractive autoremove -y --purge "$@"; }
pkg::clean()         { pkg::_apt clean; }

pkg::full_upgrade() {
    pkg::_apt_noninteractive "$@" -y full-upgrade
}

# 静默模式失败时回退到 verbose 模式重跑，让用户看到真实 apt 错误
pkg::ensure_deps() {
    [[ $_DEPS_CHECKED -eq 1 ]] && return 0

    local missing=()
    local spec cmd package
    local command_packages=(
        "jq:jq"
        "tar:tar"
        "gpg:gnupg"
    )

    for spec in "${command_packages[@]}"; do
        cmd="${spec%%:*}"
        package="${spec#*:}"
        sys::has_cmd "$cmd" || missing+=("$package")
    done

    # curl 与 wget 只需存在一个；全部缺失时优先安装 curl。
    if ! sys::has_cmd curl && ! sys::has_cmd wget; then
        missing+=("curl")
    fi

    # ca-certificates 没有同名命令，必须按软件包状态检查。
    if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("ca-certificates")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log::info "正在安装必要依赖: ${missing[*]}"
        if ! pkg::update quiet; then
            log::warn "apt-get update 静默失败，重试 verbose 模式以暴露错误..."
            pkg::update || { log::err "apt-get update 失败，请检查软件源/DNS/网络"; return 1; }
        fi
        if ! pkg::install_quiet "${missing[@]}"; then
            log::warn "依赖安装静默失败，重试 verbose 模式以暴露错误..."
            if ! pkg::install "${missing[@]}"; then
                log::err "依赖安装失败: ${missing[*]}"
                log::info "常见原因: 软件源失效 / DNS 故障 / 签名过期 / 网络受限"
                return 1
            fi
        fi
    fi
    _DEPS_CHECKED=1
}

pkg::add_gpg_key() {
    local url="$1" dest="$2" expected_fingerprint="${3:-}" mode="${4:-}"
    local staged
    staged=$(mktemp "${dest}.new.XXXXXXXX") || return 1
    if [[ "$mode" == "--dearmor" ]]; then
        if ! net::fetch "$url" | gpg --dearmor --yes -o "$staged"; then
            rm -f -- "$staged"
            return 1
        fi
    else
        if ! net::fetch "$url" > "$staged" || [[ ! -s "$staged" ]]; then
            rm -f -- "$staged"
            return 1
        fi
    fi
    if [[ -n "$expected_fingerprint" ]]; then
        local actual_fingerprint
        actual_fingerprint=$(gpg --batch --show-keys --with-colons "$staged" 2>/dev/null |
            awk -F: '$1 == "fpr" {print toupper($10); exit}')
        if [[ "$actual_fingerprint" != "${expected_fingerprint^^}" ]]; then
            rm -f -- "$staged"
            log::err "GPG 密钥指纹校验失败。"
            return 1
        fi
    fi
    chmod 0644 "$staged" || { rm -f -- "$staged"; return 1; }
    mv -f -- "$staged" "$dest"
}

pkg::write_repo() {
    local content="$1" dest="$2"
    local staged
    staged=$(mktemp "${dest}.new.XXXXXXXX") || return 1
    if ! printf '%s\n' "$content" > "$staged" || ! chmod 0644 "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    mv -f -- "$staged" "$dest"
}
