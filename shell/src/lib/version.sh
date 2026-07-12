# ==============================================================================
# version:: SemVer 校验与比较
# ==============================================================================

version::is_valid() {
    local version="${1#v}"
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?(\+([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?$ ]] || return 1

    local without_build="${version%%+*}"
    [[ "$without_build" == *-* ]] || return 0
    local prerelease="${without_build#*-}" identifier
    local identifiers=()
    IFS='.' read -r -a identifiers <<< "$prerelease"
    for identifier in "${identifiers[@]}"; do
        if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" != "0" && "$identifier" == 0* ]]; then
            return 1
        fi
    done
}

version::is_prerelease() {
    local version="${1#v}"
    version::is_valid "$version" && [[ "${version%%+*}" == *-* ]]
}

# 输出 -1、0、1，分别表示左侧版本较小、相同、较大。
version::compare() {
    local left="${1#v}" right="${2#v}"
    local LC_ALL=C
    version::is_valid "$left" && version::is_valid "$right" || return 2

    left="${left%%+*}"
    right="${right%%+*}"
    local left_pre="" right_pre=""
    if [[ "$left" == *-* ]]; then
        left_pre="${left#*-}"
        left="${left%%-*}"
    fi
    if [[ "$right" == *-* ]]; then
        right_pre="${right#*-}"
        right="${right%%-*}"
    fi

    local left_core=() right_core=() index
    IFS='.' read -r -a left_core <<< "$left"
    IFS='.' read -r -a right_core <<< "$right"
    for index in 0 1 2; do
        if (( 10#${left_core[$index]} > 10#${right_core[$index]} )); then
            printf '1\n'
            return 0
        elif (( 10#${left_core[$index]} < 10#${right_core[$index]} )); then
            printf '%s\n' '-1'
            return 0
        fi
    done

    if [[ -z "$left_pre" && -z "$right_pre" ]]; then
        printf '0\n'
        return 0
    elif [[ -z "$left_pre" ]]; then
        printf '1\n'
        return 0
    elif [[ -z "$right_pre" ]]; then
        printf '%s\n' '-1'
        return 0
    fi

    local left_ids=() right_ids=() left_id right_id max
    IFS='.' read -r -a left_ids <<< "$left_pre"
    IFS='.' read -r -a right_ids <<< "$right_pre"
    max=${#left_ids[@]}
    (( ${#right_ids[@]} > max )) && max=${#right_ids[@]}
    for (( index=0; index<max; index++ )); do
        if (( index >= ${#left_ids[@]} )); then
            printf '%s\n' '-1'
            return 0
        elif (( index >= ${#right_ids[@]} )); then
            printf '1\n'
            return 0
        fi
        left_id="${left_ids[$index]}"
        right_id="${right_ids[$index]}"
        [[ "$left_id" == "$right_id" ]] && continue

        if [[ "$left_id" =~ ^[0-9]+$ && "$right_id" =~ ^[0-9]+$ ]]; then
            if (( 10#$left_id > 10#$right_id )); then
                printf '1\n'
            else
                printf '%s\n' '-1'
            fi
        elif [[ "$left_id" =~ ^[0-9]+$ ]]; then
            printf '%s\n' '-1'
        elif [[ "$right_id" =~ ^[0-9]+$ ]]; then
            printf '1\n'
        elif [[ "$left_id" > "$right_id" ]]; then
            printf '1\n'
        else
            printf '%s\n' '-1'
        fi
        return 0
    done
    printf '0\n'
}

version::gt() {
    local result
    result=$(version::compare "$1" "$2") || return 1
    [[ "$result" -gt 0 ]]
}

version::ge() {
    local result
    result=$(version::compare "$1" "$2") || return 1
    [[ "$result" -ge 0 ]]
}
