#!/bin/bash
# 一键测速模块自检：路径解析 / 首次下载 / 临时文件清理，全程不联网不改系统
# 用法：bash tests/speedtest_selftest.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/singbox.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

awk '/^# --- 一键测速/{f=1} f&&/^_dns_config_menu\(\) \{/{exit} f' "$SRC" > "$TMP/block.sh"
grep -q '_speedtest_menu' "$TMP/block.sh" || { echo "FAIL: 抽不到一键测速代码段"; exit 1; }

CYAN='' GREEN='' YELLOW='' RED='' NC=''
_info() { :; }; _success() { :; }; _warn() { :; }; _error() { :; }
# 把真实下载换成落一个合法脚本，验证"下载成功 -> 返回路径"这条链路
DOWNLOAD_FAIL=0
_download_bash_script_atomic() {
    [ "$DOWNLOAD_FAIL" -eq 0 ] || return 1
    printf '#!/bin/bash\n:\n' > "$2"
}

source "$TMP/block.sh"
SINGBOX_DIR="$TMP/prod"; SCRIPT_DIR="$TMP/dev"
mkdir -p "$SINGBOX_DIR" "$SCRIPT_DIR"

# 1) 两处都没有 -> 指向生产目录
out=$(_speedtest_path); [ "$out" = "$SINGBOX_DIR/speedtest.sh" ] || { echo "FAIL: 无脚本时应指向 SINGBOX_DIR，实际 $out"; fail=1; }

# 2) 开发目录有 -> 优先开发目录
printf '#!/bin/bash\n:\n' > "$SCRIPT_DIR/speedtest.sh"
out=$(_speedtest_path); [ "$out" = "$SCRIPT_DIR/speedtest.sh" ] || { echo "FAIL: 开发目录存在时应优先它，实际 $out"; fail=1; }

# 3) 缺失时 ensure 会下载并回传路径
rm -f "$SCRIPT_DIR/speedtest.sh"
out=$(_speedtest_ensure); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$SINGBOX_DIR/speedtest.sh" ] && [ -f "$out" ] \
    || { echo "FAIL: ensure 未下载到生产目录 (rc=$rc out=$out)"; fail=1; }

# 4) 下载失败时 ensure 返回 1，且不留半成品
rm -f "$SINGBOX_DIR/speedtest.sh"; DOWNLOAD_FAIL=1
_speedtest_ensure >/dev/null; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: 下载失败时应返回 1，实际 $rc"; fail=1; }
[ -e "$SINGBOX_DIR/speedtest.sh" ] && { echo "FAIL: 下载失败不该产生文件"; fail=1; }
DOWNLOAD_FAIL=0

# 5) 清理只删 sp-github-i-abc
mkdir -p "$SINGBOX_DIR/sp-github-i-abc/sub"; touch "$SINGBOX_DIR/keep.txt"
_speedtest_clean; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 清理返回 $rc"; fail=1; }
[ -d "$SINGBOX_DIR/sp-github-i-abc" ] && { echo "FAIL: 临时目录没删掉"; fail=1; }
[ -f "$SINGBOX_DIR/keep.txt" ] || { echo "FAIL: 清理误删了别的文件"; fail=1; }

# 6) 依赖补齐：缺 bc 时调用 _pkg_install，齐了就不动包管理器
PKG_CALLED=""
_pkg_install() { PKG_CALLED="$*"; FAKE_MISSING_BC=0; return 0; }
_cmd_exists() { case "$1" in bc) [ "${FAKE_MISSING_BC:-0}" = "1" ] && return 1 ;; esac; return 0; }
FAKE_MISSING_BC=1
_speedtest_ensure_deps; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 缺 bc 时补齐后应返回 0，实际 $rc"; fail=1; }
[ "$PKG_CALLED" = "bc" ] || { echo "FAIL: 应只请求安装 bc，实际 '$PKG_CALLED'"; fail=1; }
FAKE_MISSING_BC=0; PKG_CALLED=""
_speedtest_ensure_deps; rc=$?
[ "$rc" -eq 0 ] && [ -z "$PKG_CALLED" ] || { echo "FAIL: 依赖齐全时不该动包管理器"; fail=1; }
# 装完仍缺 -> 报错退出
_cmd_exists() { return 1; }
_speedtest_ensure_deps >/dev/null; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: 装完仍缺依赖时应返回 1，实际 $rc"; fail=1; }

# 7) timeout 垫片：GNU timeout 在就不改 PATH；BusyBox 式 timeout 就生成剥参垫片
timeout() { [ "$1" = "--foreground" ] && return 1; return 0; }   # 模拟 BusyBox 的 timeout
out=$(_speedtest_timeout_shim); rc=$?
[ "$rc" -eq 0 ] && [ -x "$out/timeout" ] || { echo "FAIL: 应生成可执行的 timeout 垫片，实际 '$out' rc=$rc"; fail=1; }
if [ -x /bin/busybox ]; then
    # 剥掉 --foreground 后应正常执行 true（不被 busybox 拒参）
    "$out/timeout" --foreground 5 true || { echo "FAIL: 垫片没能剥掉 --foreground"; fail=1; }
fi
unset -f timeout
out=$(_speedtest_timeout_shim); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: GNU timeout 在时不该生成垫片，实际 '$out'"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: 一键测速模块 10 项自检通过" || exit 1
