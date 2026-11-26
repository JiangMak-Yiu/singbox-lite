#!/bin/bash
# 网络加速模块自检：不碰真实 sysctl，只验证落盘/逐条应用/跳过/拒绝分支
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

# stub：-n 查询 / -w 写入；FAKE_UNSUPPORTED 里的键模拟"内核不支持"
FAKE_AVAIL=""; FAKE_UNSUPPORTED=""; FAKE_CC="cubic"; APPLIED_KEYS=()
sysctl() {
    local key value
    case "$1" in
        -n)
            case "$2" in
                net.ipv4.tcp_congestion_control) echo "$FAKE_CC" ;;
                net.ipv4.tcp_available_congestion_control) printf '%s\n' "$FAKE_AVAIL" ;;
                net.core.default_qdisc) echo "fq_codel" ;;
            esac ;;
        -w)
            key=${2%%=*}; value=${2#*=}
            case " $FAKE_UNSUPPORTED " in
                *" $key "*) return 1 ;;
            esac
            [ "$key" = "net.ipv4.tcp_congestion_control" ] && FAKE_CC="$value"
            APPLIED_KEYS+=("$key")
            return 0 ;;
        *) return 0 ;;
    esac
}
modprobe() { return 0; }
tc() { return 0; }
ip() { echo "default via 1.2.3.4 dev eth0"; }
uname() { echo "fake-kernel"; }

source "$TMP/block.sh"
NET_TUNE_CONF="$TMP/99-sb-net-tune.conf"
NET_TUNE_EXTRA_CONF="$TMP/99-sb-net-tune-extra.conf"
NET_TUNE_MODLOAD="$TMP/99-bbr.conf"
NET_TUNE_MODFILE="$TMP/modules"

# 1) 内核支持 bbr -> 三个文件落盘 + 逐条应用 + 返回 0
FAKE_AVAIL="reno cubic bbr"; FAKE_CC="cubic"; APPLIED_KEYS=()
: > "$NET_TUNE_MODFILE"
_net_tune_bbr; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 支持 bbr 时应返回 0，实际 $rc"; fail=1; }
grep -qx "net.ipv4.tcp_congestion_control=bbr" "$NET_TUNE_CONF" || { echo "FAIL: 主配置缺 bbr 行"; fail=1; }
grep -qx "net.core.default_qdisc=fq" "$NET_TUNE_CONF" || { echo "FAIL: 主配置缺 fq 队列"; fail=1; }
grep -qx "tcp_bbr" "$NET_TUNE_MODLOAD" || { echo "FAIL: modules-load.d 未落盘"; fail=1; }
grep -qx "tcp_bbr" "$NET_TUNE_MODFILE" || { echo "FAIL: /etc/modules 未追加（Alpine 开机加载）"; fail=1; }
[ "${#APPLIED_KEYS[@]}" -eq 2 ] || { echo "FAIL: 应逐条应用 2 个键，实际 ${#APPLIED_KEYS[@]}"; fail=1; }

# 2) 个别键内核不支持（PVE/LXC 里 default_qdisc 常见）不应整批失败
FAKE_UNSUPPORTED="net.core.default_qdisc"; APPLIED_KEYS=()
_net_tune_bbr; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 个别键不支持时仍应成功，实际 $rc"; fail=1; }
[ "${APPLIED_KEYS[0]:-}" = "net.ipv4.tcp_congestion_control" ] || { echo "FAIL: bbr 键没被应用"; fail=1; }
FAKE_UNSUPPORTED=""

# 3) 内核对 bbr 无支持 -> 返回 1 且不动任何文件
FAKE_AVAIL="reno cubic"
rm -f "$NET_TUNE_CONF" "$NET_TUNE_MODLOAD" "$NET_TUNE_MODFILE"; APPLIED_KEYS=()
_net_tune_bbr; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: 不支持 bbr 时应返回 1，实际 $rc"; fail=1; }
[ -e "$NET_TUNE_CONF" ] && { echo "FAIL: 不支持时不该写配置"; fail=1; }
[ -e "$NET_TUNE_MODLOAD" ] && { echo "FAIL: 不支持时不该写模块文件"; fail=1; }
[ -e "$NET_TUNE_MODFILE" ] && { echo "FAIL: 不支持时不该改 /etc/modules"; fail=1; }

# 4) 调优分支：8 条参数落盘并逐条应用
FAKE_AVAIL="reno cubic bbr"; APPLIED_KEYS=()
_net_tune_extra; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: 调优写入失败 rc=$rc"; fail=1; }
# 用 awk 数行：本机 grep 对 '^net\.[a-z0-9.]*=' 这类锚定+字符类+量词组合会误报 0
n=$(awk -F= '/^net\./ && NF>=2 {n++} END{print n+0}' "$NET_TUNE_EXTRA_CONF" 2>/dev/null); n=${n:-0}
[ "$n" -eq 8 ] || { echo "FAIL: 调优参数应为 8 条，实际 $n"; fail=1; }
[ "${#APPLIED_KEYS[@]}" -eq 8 ] || { echo "FAIL: 调优应逐条应用 8 个键，实际 ${#APPLIED_KEYS[@]}"; fail=1; }

# 5) 容器识别：只有 /proc/1/environ 带 container=lxc 等标记才算容器
if tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qx 'container=lxc'; then
    _is_container_env || { echo "FAIL: 本机是 LXC 却未识别"; fail=1; }
else
    _is_container_env && { echo "FAIL: 裸机被误判为容器"; fail=1; }
fi

# 6) 状态行不改任何东西
_net_tune_status >/dev/null || { echo "FAIL: 状态查询报错"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: 网络加速模块 6 项自检通过" || exit 1
