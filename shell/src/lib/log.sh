# ==============================================================================
# log:: 日志输出
# ==============================================================================

log::info() { printf '%s[INFO]%s %s\n' "$GREEN" "$PLAIN" "$1"; }
log::warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$PLAIN" "$1"; }
log::err()  { printf '%s[ERROR]%s %s\n' "$RED" "$PLAIN" "$1"; }
log::step() { printf '%s[*]%s %s\n' "$BLUE" "$PLAIN" "$1"; }
