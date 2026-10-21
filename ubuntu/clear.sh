#!/bin/bash
# 清空 firewall.sh 装载的全部规则, 恢复默认全通（firewall.sh 的逆操作）
# 顺序与 firewall.sh 同理: 先恢复 ACCEPT 策略再清规则 ——
# 若旧策略是 DROP, 先清规则会瞬间锁死整机
set -u

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO=sudo

for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  # 只读探测: IPv6 被内核禁用时 ip6tables 一切操作报错, 整体跳过
  if ! $SUDO "$ipt" -S >/dev/null 2>&1; then
    echo "[!] $ipt 不可用（可能 IPv6 被禁用）, 跳过" >&2
    continue
  fi
  $SUDO "$ipt" -P INPUT ACCEPT
  $SUDO "$ipt" -P FORWARD ACCEPT
  $SUDO "$ipt" -P OUTPUT ACCEPT
  $SUDO "$ipt" -F
  $SUDO "$ipt" -X 2>/dev/null || true      # 删自定义链(DNSFILTER/_new/_old 等)
  for t in nat mangle raw security; do     # 与 firewall.sh 清相同的一组表
    $SUDO "$ipt" -t "$t" -F 2>/dev/null && $SUDO "$ipt" -t "$t" -X 2>/dev/null || true
  done
  echo "[+] 已清空 $ipt 全部规则, 策略恢复 ACCEPT"
done
