# ==============================================================================
# net:: 网络下载（统一 UA / 超时 / 重试）
# ==============================================================================

net::fetch() {
    local url="$1"
    [[ "$url" == https://* ]] || {
        log::err "拒绝非 HTTPS 下载地址。"
        return 1
    }
    if sys::has_cmd curl; then
        curl --fail --location --retry 2 --connect-timeout 5 --max-time 60 \
            --proto '=https' --proto-redir '=https' \
            --silent --show-error -A "sing-box/1.0" "$url"
    else
        wget --https-only -q -O- -T 60 -t 2 --user-agent="sing-box/1.0" "$url"
    fi
}

net::download() {
    local url="$1" dest="$2"
    [[ "$url" == https://* ]] || {
        log::err "拒绝非 HTTPS 下载地址。"
        return 1
    }
    if sys::has_cmd curl; then
        curl --fail --location --retry 3 --connect-timeout 10 --max-time 180 \
            --proto '=https' --proto-redir '=https' \
            --silent --show-error -A "sing-box/1.0" -o "$dest" "$url"
    else
        wget --https-only -q -T 180 -t 3 --user-agent="sing-box/1.0" -O "$dest" "$url"
    fi
}
