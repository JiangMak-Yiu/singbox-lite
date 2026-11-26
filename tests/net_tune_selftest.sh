#!/bin/bash
# 网络加速模块自检：不碰真实 sysctl，只验证两条分支的落盘/返回行为
# 用法：bash tests/net_tune_selftest.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/singbox.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

# 从主脚本里抽出网络加速那一段（到 _dns_config_menu 之前）
awk '/^# --- 网络加速/{f=1} f&&/^_dns_config_menu\(\) \{/{exit} f' "$SRC" > "$TMP/block.sh"
[ -s "$TMP/block.sh" ] && grep -q '_net_tune_bbr' "$TMP/block.sh" || { echo "FAIL: 抽不到网络加速代码段"; exit 1; }

CYAN='' GREEN='' YELLOW='' RED='' NC=''
_info() { :; }; _success() { :; }; _warn() { :; }; _error() { :; }

SYSCTL_P=(); SYSCTL_P_SET=0
sysctl() {
    case "$1" in
        -n)
            case "$2" in
                net.ipv4.tcp_congestion_control) echo cubic ;;
                net.ipv4.tcp_available_congestion_control) printf '%s\n' "$FAKE_AVAIL" ;;
                net.core.default_qdisc) echo fq_codel ;;
            esac ;;
        -p) [ -f "$2" ] || return 1; SYSCTL_P+=("$2"); return 0 ;;
        *) return 0 ;;
    esac
}
modprobe() { return "${FAKE_MODPROBE:-0}"; }
tc() { TC_CALLED=1; return 0; }
ip() { echo "default via 1.2.3.4 dev eth0"; }
uname() { echo "fake-kernel"; }

source "$TMP/block.sh"
NET_TUNE_CONF="$TMP/99-sb-net-tune.conf"
NET_TUNE_EXTRA_CONF="$TMP/99-sb-net-tune-extra.conf"
NET_TUNE_MODLOAD="$TMP/99-bbr.conf"

# 分支一：内核支持 bbr -> 落盘 3 个文件 + sysctl -p + 返回 0
FAKE_AVAIL="reno cubic bbr"
_net_tune_bbr; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 支持 bbr 时应返回 0，实际 $rc"; fail=1; }
grep -qx "net.ipv4.tcp_congestion_control=bbr" "$NET_TUNE_CONF" || { echo "FAIL: 主配置缺 bbr 行"; fail=1; }
grep -qx "net.core.default_qdisc=fq" "$NET_TUNE_CONF" || { echo "FAIL: 主配置缺 fq 队列"; fail=1; }
grep -qx "tcp_bbr" "$NET_TUNE_MODLOAD" || { echo "FAIL: 开机模块未落盘"; fail=1; }
[ "${SYSCTL_P[0]:-}" = "$NET_TUNE_CONF" ] || { echo "FAIL: 未应用主配置"; fail=1; }

# 分支二：内核对 bbr 无支持 -> 返回 1 且不动任何文件
FAKE_AVAIL="reno cubic"
rm -f "$NET_TUNE_CONF" "$NET_TUNE_MODLOAD"; SYSCTL_P=()
_net_tune_bbr; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: 不支持 bbr 时应返回 1，实际 $rc"; fail=1; }
[ -e "$NET_TUNE_CONF" ] && { echo "FAIL: 不支持时不该写配置"; fail=1; }
[ -e "$NET_TUNE_MODLOAD" ] && { echo "FAIL: 不支持时不该写模块文件"; fail=1; }

# 调优分支：8 条参数全部落盘
FAKE_AVAIL="reno cubic bbr"
_net_tune_extra; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 调优写入失败 rc=$rc"; fail=1; }
# 用 awk 数行：本机 grep 对 '^net\.[a-z0-9.]*=' 这类锚定+字符类+量词组合会误报 0
n=$(awk -F= '/^net\./ && NF>=2 {n++} END{print n+0}' "$NET_TUNE_EXTRA_CONF" 2>/dev/null); n=${n:-0}
[ "$n" -eq 8 ] || { echo "FAIL: 调优参数应为 8 条，实际 $n"; fail=1; }

# 状态行不改任何东西
_net_tune_status >/dev/null || { echo "FAIL: 状态查询报错"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: 网络加速模块 4 项自检通过" || exit 1
