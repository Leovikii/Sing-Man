# ==============================================================================
# net:: 网络下载（统一 UA / 超时 / 重试）
# ==============================================================================

net::fetch() {
    local url="$1"
    if sys::has_cmd curl; then
        curl --fail --location --retry 2 --connect-timeout 5 --max-time 60 \
            --silent --show-error -A "sing-box/1.0" "$url"
    else
        wget -q -O- -T 60 -t 2 --user-agent="sing-box/1.0" "$url"
    fi
}

net::download() {
    local url="$1" dest="$2"
    if sys::has_cmd curl; then
        curl --fail --location --retry 3 --connect-timeout 10 --max-time 180 \
            --silent --show-error -A "sing-box/1.0" -o "$dest" "$url"
    else
        wget -q -T 180 -t 3 --user-agent="sing-box/1.0" -O "$dest" "$url"
    fi
}
