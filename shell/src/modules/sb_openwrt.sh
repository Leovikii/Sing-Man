# ==============================================================================
# OpenWrt: 官方 GitHub 正式版 APK，软件包与服务均使用原生机制
# ==============================================================================

sb::require_openwrt_package() {
    if ! apk info --exists sing-box >/dev/null 2>&1 &&
        { sys::has_cmd sing-box || [[ -e "$SB_INIT_FILE" || -L "$SB_INIT_FILE" ]]; }; then
        log::err "检测到非 APK 安装的 Sing-box，请先备份并自行迁移，脚本不会覆盖现有核心或服务。"
        return 1
    fi
    if sys::has_cmd sing-box && [[ "$(command -v sing-box)" != "$SB_BINARY_FILE" ]]; then
        log::err "PATH 中存在其他 Sing-box 核心，请先解决路径冲突。"; return 1
    fi
}

sb::sync_openwrt_config_path() {
    local configured
    configured=$(uci -q get sing-box.main.conffile) || configured=""
    configured="${configured:-/etc/sing-box/config.json}"
    if [[ "$configured" != /* ]]; then
        log::err "UCI conffile 必须是绝对路径，无法安全管理配置。"; return 1
    fi
    SB_CONFIG_FILE="$configured"
    SB_CONFIG_DIR=$(dirname "$configured")
}

sb::download_openwrt_apk() {
    local release="$1" version="$2" dest="$3" arch asset url digest actual
    arch=$(apk --print-arch) || return 1
    [[ "$arch" =~ ^[a-zA-Z0-9_-]+$ ]] || { log::err "无法识别 APK 架构。"; return 1; }
    asset="sing-box_${version}_openwrt_${arch}.apk"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
    digest=$(jq -er --arg name "$asset" --arg url "$url" --arg tag "v$version" '
        select(.tag_name == $tag and .draft == false and .prerelease == false) |
        [.assets[] | select(.name == $name and .browser_download_url == $url)] |
        select(length == 1) | .[0].digest' <<< "$release") || {
        log::err "正式版缺少当前架构的官方 OpenWrt APK: $asset"; return 1;
    }
    if [[ ! "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
        log::err "官方 APK 缺少有效 SHA-256 摘要，已取消安装。"; return 1
    fi
    log::info "正在下载官方 OpenWrt APK v$version ($arch)..."
    net::download "$url" "$dest" || return 1
    actual=$(sha256sum "$dest" | awk '{print $1}') || return 1
    digest="${digest#sha256:}"
    if [[ "${actual,,}" != "${digest,,}" ]]; then
        log::err "APK SHA-256 校验失败，未执行安装。"; return 1
    fi
}

sb::restore_openwrt_package() {
    local version="$1" was_active="$2" release
    local previous="$TMP_DIR/sing-box-previous.apk"
    log::warn "正在尝试通过原生 APK 恢复上一正式版 v$version..."
    release=$(net::fetch "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$version") &&
        sb::download_openwrt_apk "$release" "$version" "$previous" &&
        apk add --allow-untrusted "$previous" || {
        log::err "原生 APK 回滚失败，配置已保留，请检查 $(svc::log_hint) 并手动恢复核心。"; return 1
    }
    if [[ "$was_active" -eq 1 ]]; then
        svc::start sing-box && svc::wait_active sing-box || {
            log::err "上一版 APK 已恢复，但服务仍无法启动，请检查 $(svc::log_hint)。"; return 1;
        }
    fi
}

sb::install_openwrt() {
    sb::require_openwrt_package || return 1
    sb::sync_openwrt_config_path || return 1
    if ! sys::has_procd; then
        log::err "当前环境缺少原生 procd / ubus，无法安装服务。"; return 1
    fi
    local release tag version current="" had_package=0 was_active=0 autostart=""
    log::info "正在检查 Sing-box 官方 GitHub 最新正式版..."
    release=$(net::fetch "$SB_RELEASE_URL") || return 1
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' <<< "$release") || {
        log::err "GitHub 未返回有效的正式版 Release。"; return 1;
    }
    version="${tag#v}"
    if ! version::is_valid "$version" || version::is_prerelease "$version"; then
        log::err "正式版版本号无效: $tag"; return 1
    fi
    if apk info --exists sing-box >/dev/null 2>&1; then
        had_package=1
        current=$(sb::version)
        if version::ge "$current" "$version"; then
            log::info "当前核心 v$current 已是最新或更新，无需替换。"; return 0
        fi
        autostart=$(svc::autostart_state sing-box) || {
            log::err "无法读取原自启设置，已取消更新。"; return 1;
        }
        svc::is_active sing-box && was_active=1
    fi
    local package="$TMP_DIR/sing-box.apk" extracted="$TMP_DIR/sing-box-package"
    sb::download_openwrt_apk "$release" "$version" "$package" || return 1
    rm -rf -- "$extracted" && mkdir -p "$extracted" || return 1
    # 官方 APK 未使用系统信任的仓库签名；仅对已核对 GitHub 摘要的本地文件放行。
    if ! apk extract --allow-untrusted --destination "$extracted" "$package"; then
        log::err "APK 提取失败，未执行安装。"; return 1
    fi
    local candidate="$extracted/usr/bin/sing-box" candidate_version config="$SB_CONFIG_FILE" new_config=0
    if ! candidate_version=$("$candidate" version | awk 'NR == 1 {print $3}') || [[ "$candidate_version" != "$version" ]]; then
        log::err "APK 核心无法运行或版本不匹配，未执行安装。"; return 1
    fi
    if [[ ! -f "$config" ]]; then
        config="$TMP_DIR/sing-box-default.json"
        printf '%s\n' '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$config" || return 1
        new_config=1
    fi
    if ! "$candidate" check -c "$config"; then
        log::err "现有配置不兼容新核心，原软件包及服务未修改。"; return 1
    fi
    rm -rf -- "$extracted" || return 1
    # 不执行全局 upgrade；依赖与包文件的安装和配置保护交由 APK 处理。
    if ! apk add --allow-untrusted "$package"; then
        if [[ "$had_package" -eq 1 ]]; then
            svc::restore_autostart sing-box "$autostart" || log::err "恢复原自启设置失败。"
        fi
        log::err "Sing-box APK 安装失败，请检查 APK 输出及设备软件源。"; return 1
    fi
    if [[ "$had_package" -eq 1 ]]; then
        svc::restore_autostart sing-box "$autostart" || return 1
        if [[ "$was_active" -eq 0 ]]; then svc::stop sing-box || return 1; fi
    fi
    if [[ "$new_config" -eq 1 ]]; then
        # 官方示例含固定密码及监听端口；首次安装使用无入站的基础配置。
        mkdir -p "$SB_CONFIG_DIR" && install -m 0600 "$config" "$SB_CONFIG_FILE" || return 1
    fi
    if [[ "$had_package" -eq 0 ]]; then
        svc::ensure_running sing-box || return 1
    elif [[ "$was_active" -eq 1 ]]; then
        if ! { svc::restart sing-box && svc::wait_active sing-box; }; then
            log::err "新软件包启动失败。"
            svc::stop sing-box || log::warn "停止服务失败。"
            if version::is_valid "$current" && ! version::is_prerelease "$current"; then
                local rollback_rc=0
                sb::restore_openwrt_package "$current" "$was_active" || rollback_rc=$?
                svc::restore_autostart sing-box "$autostart" || return 1
                [[ "$rollback_rc" -eq 0 ]] || return 1
            fi
            return 1
        fi
    fi
    log::info "Sing-box v$version 已通过官方 OpenWrt APK 安装，使用包自带 procd / UCI 服务。"
    if [[ "$new_config" -eq 1 ]]; then
        log::info "已使用不监听端口的基础配置，请更新实际配置；网络及防火墙设置需自行完成。"
    fi
}

sb::uninstall_openwrt() {
    sb::require_openwrt_package || return 1
    sb::sync_openwrt_config_path || return 1
    if ! apk info --exists sing-box >/dev/null 2>&1; then log::info "Sing-box APK 未安装。"; return 0; fi
    ui::confirm "确认通过 APK 卸载 Sing-box?（共享依赖将保留）" || return 0
    svc::stop sing-box && svc::disable sing-box || {
        log::err "停止服务或禁用开机启动失败，未卸载软件包。"; return 1;
    }
    # 避免 apk del 顺带移除因核心安装而引入的共享组件。
    local dependencies=() dependency dependency_info
    dependency_info=$(apk info --installed --depends sing-box) || return 1
    while IFS= read -r dependency; do
        [[ -z "$dependency" || "$dependency" == *' '* ]] || dependencies+=("$dependency")
    done < <(sed '1d;/^$/d' <<< "$dependency_info")
    if [[ ${#dependencies[@]} -gt 0 ]]; then
        apk add "${dependencies[@]}" || { log::err "无法保留 Sing-box 依赖，已取消卸载。"; return 1; }
    fi
    local backup
    backup=$(mktemp -d "$TMP_DIR/uninstall.XXXXXXXX") || return 1
    if [[ -f "$SB_CONFIG_FILE" ]]; then cp -p -- "$SB_CONFIG_FILE" "$backup/config" || return 1; fi
    if [[ -f "$SB_UCI_FILE" ]]; then cp -p -- "$SB_UCI_FILE" "$backup/uci" || return 1; fi
    apk del sing-box || { log::err "Sing-box APK 卸载失败，配置未清理。"; return 1; }
    hash -r
    if [[ -f "$backup/config" ]]; then
        mkdir -p "$(dirname "$SB_CONFIG_FILE")" && cp -p -- "$backup/config" "$SB_CONFIG_FILE" || return 1
    fi
    if [[ -f "$backup/uci" ]]; then
        mkdir -p "$(dirname "$SB_UCI_FILE")" && cp -p -- "$backup/uci" "$SB_UCI_FILE" || return 1
    fi
    if ui::confirm "是否同时删除配置文件 $SB_CONFIG_FILE 及 $SB_UCI_FILE?"; then
        rm -f -- "$SB_CONFIG_FILE" "$SB_UCI_FILE" || return 1
    fi
    log::info "Sing-box APK 已卸载。"
}
