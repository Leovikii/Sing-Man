#!/bin/bash
#
# build.sh — 把 src/ 下的模块拼接成单文件 sm.sh
#
# 用法:
#   bash shell/build.sh             # 在仓库任意位置执行均可
#   bash shell/build.sh --check     # 只跑语法检查不写文件
#
# 拼接顺序由 SOURCES 数组控制（自顶向下，下层在前、上层在后）。
# modules/*.sh 与 menu 子菜单按 glob 自动收录；新增模块无需改 build.sh。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OUT_FILE="$SCRIPT_DIR/sm.sh"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# 颜色
G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
info() { printf '%b[build]%b %s\n' "$G" "$N" "$1"; }
warn() { printf '%b[build]%b %s\n' "$Y" "$N" "$1"; }
die()  { printf '%b[build]%b %s\n' "$R" "$N" "$1" >&2; exit 1; }

[[ -d "$SRC_DIR" ]] || die "源码目录不存在: $SRC_DIR"

# ---- 拼接顺序 -----------------------------------------------------------------
# 显式列出依赖关系敏感的文件；modules/menu 的子文件用 glob 自动收录。
SOURCES=(
    "_prelude.sh"
    "config.sh"
    "lib/log.sh"
    "lib/ui.sh"
    "lib/sys.sh"
    "lib/version.sh"
    "lib/net.sh"
    "lib/pkg.sh"
    "lib/svc.sh"
    "self.sh"
)

# modules/*.sh - 业务模块彼此独立，按文件名排序
shopt -s nullglob
for f in "$SRC_DIR"/modules/*.sh; do
    SOURCES+=("modules/$(basename "$f")")
done

# menu/*.sh - main.sh 必须最后；其他子菜单按文件名排序
for f in "$SRC_DIR"/menu/*.sh; do
    name=$(basename "$f")
    [[ "$name" == "main.sh" ]] && continue
    SOURCES+=("menu/$name")
done
SOURCES+=("menu/main.sh")
SOURCES+=("entry.sh")
shopt -u nullglob

# ---- 检查所有源文件存在 -------------------------------------------------------
for rel in "${SOURCES[@]}"; do
    [[ -f "$SRC_DIR/$rel" ]] || die "缺少源文件: src/$rel"
done

# ---- 构建到临时文件 -----------------------------------------------------------
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

info "拼接 ${#SOURCES[@]} 个源文件..."
for rel in "${SOURCES[@]}"; do
    src="$SRC_DIR/$rel"
    # 第一个文件原样保留（含 shebang），后续文件去掉 shebang 行
    if [[ "$rel" == "_prelude.sh" ]]; then
        cat "$src" >> "$TMP_OUT"
    else
        echo "" >> "$TMP_OUT"
        echo "# >>> src/$rel" >> "$TMP_OUT"
        # 跳过首行 shebang（如有）
        if head -n1 "$src" | grep -q '^#!'; then
            tail -n +2 "$src" >> "$TMP_OUT"
        else
            cat "$src" >> "$TMP_OUT"
        fi
    fi
done

# ---- 语法检查 -----------------------------------------------------------------
info "bash -n 语法检查..."
if ! bash -n "$TMP_OUT"; then
    die "语法检查失败，未写入 $OUT_FILE"
fi

# 可选 shellcheck
if command -v shellcheck >/dev/null 2>&1; then
    info "shellcheck (warning+)..."
    shellcheck -S warning "$TMP_OUT" || warn "shellcheck 有警告，请检查（不阻断构建）"
fi

# ---- 写入产物 -----------------------------------------------------------------
if [[ $CHECK_ONLY -eq 1 ]]; then
    info "--check 模式：未写入文件，仅做了语法检查"
    exit 0
fi

mv "$TMP_OUT" "$OUT_FILE"
trap - EXIT
chmod +x "$OUT_FILE"

LINES=$(wc -l < "$OUT_FILE")
SIZE=$(wc -c < "$OUT_FILE")
info "构建成功: $OUT_FILE  (${LINES} 行, ${SIZE} 字节)"
