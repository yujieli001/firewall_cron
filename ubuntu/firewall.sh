#!/bin/bash
# 域名白名单: 只从外部文件读取(默认同目录 dns.txt, 由 get_dns.py 实地访问采集生成,
# 也可调用时以第一个参数指定其它列表文件), 脚本内不再内嵌域名列表
domains=()

# ====================================================================
# 前置检查
# ====================================================================

set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请以 root 运行" >&2
  exit 1
fi

# cron 定时刷新与手动执行可能同时运行, 两者交叉改 iptables 链会产生
# 混乱的中间态, 用文件锁保证同时只有一个实例
if command -v flock >/dev/null 2>&1 && [ -d /run/lock ]; then
  exec 9>/run/lock/firewall.lock
  flock -n 9 || { echo "[*] 已有实例在运行，本次退出"; exit 0; }
fi

# 只依赖 iptables 包与 Ubuntu 基础系统自带命令(getent/timeout/awk), 不再需要 dnsutils/ipset
for cmd in getent timeout awk iptables ip6tables iptables-restore ip6tables-restore; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[!] 缺少依赖: $cmd（iptables 由 iptables 包提供, 其余为基础系统自带）" >&2
    exit 1
  fi
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 域名列表来源优先级: 命令行参数 > 脚本同目录 dns.txt（已无内嵌列表）。
# dns.txt 由 get_dns.py 生成（LF 无 BOM）; 若列表被 Windows 端工具改过,
# 可能带 UTF-8 BOM 和 CRLF，直接逐行读会得到尾部 \r 的域名导致解析全部
# 静默失败，必须先清洗。
# 纯 IP 行无需过滤: getent 对数字地址直接返回，正好按 IP 放行。
DOMAIN_FILE="${1:-$SCRIPT_DIR/dns.txt}"

if [ -f "$DOMAIN_FILE" ]; then
  echo "[+] 从 $DOMAIN_FILE 读取域名"
  mapfile -t domains < <(
    sed 's/\r//; 1s/^\xEF\xBB\xBF//' "$DOMAIN_FILE" \
      | grep -v '^#' | grep -v '^\*' | grep -v '^[[:space:]]*$'
  )
fi

if [ "${#domains[@]}" -eq 0 ]; then
  echo "[!] 域名列表为空，保持现有规则不变" >&2
  exit 1
fi
echo "[+] 域名数量: ${#domains[@]}"

# ====================================================================
# 常见 DNS 服务器与 DoH 入口（硬编码, 与 dns.txt 无关, 一并解析并入白名单）:
# 53 端口的普通 DNS 查询本就不在拦截范围, 这里显式放行的实际意义是 DoH ——
# 它走 443, 目标 IP 若不在白名单会被本防火墙拦下, 等于把 DNS 通道自己掐断。
# IP 字面量由 getent 直接返回, 不需外发查询, 不随 DNS 故障缺失;
# DoH 域名解析失败只少几条规则, 无害
# ====================================================================
DNS_SERVERS=(
"223.5.5.5"             # 阿里 AliDNS
"223.6.6.6"
"119.29.29.29"          # 腾讯 DNSPod
"182.254.116.116"
"114.114.114.114"       # 114DNS
"114.114.115.115"
"8.8.8.8"               # Google
"8.8.4.4"
"1.1.1.1"               # Cloudflare
"2400:3200::1"          # 阿里 AliDNS IPv6
"240c::6666"            # 腾讯 DNSPod IPv6
"240c::6644"
"2001:4860:4860::8888"  # Google IPv6
"2606:4700:4700::1111"  # Cloudflare IPv6
)
DNS_DOMAINS=(
"dns.alidns.com"        # 阿里 DoH 入口
"doh.pub"               # DNSPod DoH 入口
"dns.google"            # Google DoH 入口
"cloudflare-dns.com"    # Cloudflare DoH 入口
)

# ====================================================================
# 并行解析全部 A / AAAA 记录（不依赖 dig/dnsutils, 用系统自带 getent;
# 域名列表 = 外部文件 + 硬编码 DNS 服务器/DoH 域名）
#   ahostsv4/ahostsv6 分别只返回 v4/v6 地址, 每地址一行, 取第一列
#   timeout 5: 兜住 glibc 解析器默认 5s×2 的重试, 防 DNS 故障时长挂
#   走系统解析器: /etc/hosts 手工记录与本地 DNS 缓存自动生效
#   取全部地址而非 tail -n1: 多 A 记录的 CDN 域名旧版每次只随机放行一个 IP
# ====================================================================

# DNS 预检: 解析器整体不可用时快速退出保持旧规则, 不空跑上千次注定失败的查询
if ! timeout 5 getent ahostsv4 baidu.com >/dev/null 2>&1 \
   && ! timeout 5 getent ahostsv4 qq.com >/dev/null 2>&1; then
  echo "[!] DNS 预检失败, 系统解析器不可用, 保持现有规则不变" >&2
  exit 1
fi

# ====================================================================
# 先清空防火墙全部原有规则, 再由本脚本从零装载白名单:
# filter 表内置链策略恢复 ACCEPT 后整表清空、删除自定义链,
# nat/mangle 等表存在则一并清（会连带清掉 ufw/docker 等的规则）; IPv4/IPv6 各一遍。
# 先改策略后清规则, 顺序不可反: 若旧策略是 DROP, 先清规则会瞬间锁死整机。
# 从此刻到白名单链挂上, 过滤规则为空——列表检查与 DNS 预检已在前面完成,
# 该窗口通常只有解析所用的几秒; 若解析中途失败退出, 会带着空规则集大声
# 报错, 需人工重跑（"从零开始"语义的必然代价）
# ====================================================================

# 部分机器内核禁用了 IPv6: ip6tables 命令存在但操作会报错。
# 探测一次, 失败则后续 v6 操作整体跳过（此时也不存在走 v6 绕过的前提）
HAVE_V6=1
ip6tables -n -L OUTPUT >/dev/null 2>&1 || {
  HAVE_V6=0
  echo "[!] ip6tables 不可用（IPv6 被禁用？）, 本次仅处理 IPv4" >&2
}

reset_firewall() { # reset_firewall <iptables命令>
  local cmd=$1 t
  $cmd -P INPUT ACCEPT
  $cmd -P FORWARD ACCEPT
  $cmd -P OUTPUT ACCEPT
  $cmd -F
  $cmd -X 2>/dev/null || true          # 删光自定义链; 个别被残留引用删不掉的也无害
  for t in nat mangle raw security; do # 其它已加载的表一并清, 不存在则静默跳过
    $cmd -t "$t" -F >/dev/null 2>&1 && $cmd -t "$t" -X >/dev/null 2>&1 || true
  done
  echo "[+] 已清空 $cmd 的全部原有规则"
}

reset_firewall iptables
if [ "$HAVE_V6" -eq 1 ]; then
  reset_firewall ip6tables
fi

mapfile -t IPS4 < <(
  printf '%s\n' "${domains[@]}" "${DNS_SERVERS[@]}" "${DNS_DOMAINS[@]}" \
    | xargs -r -P 16 -n 1 timeout 5 getent ahostsv4 \
    | awk '{print $1}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
)

mapfile -t IPS6 < <(
  printf '%s\n' "${domains[@]}" "${DNS_SERVERS[@]}" "${DNS_DOMAINS[@]}" \
    | xargs -r -P 16 -n 1 timeout 5 getent ahostsv6 \
    | awk '{print $1}' \
    | grep -E '^[0-9A-Fa-f:]+:[0-9A-Fa-f:]+$' | sort -u
)

# 解析全军覆没时不能带病继续装载。注意此刻旧规则已被清空, 必须修复 DNS 后重跑
if [ "${#IPS4[@]}" -eq 0 ]; then
  echo "[!] 未解析到任何 IPv4, 判定为 DNS 故障; 原有规则已被清空, 请修复 DNS 后立即重跑本脚本" >&2
  exit 1
fi

echo "[+] 解析得到 IPv4: ${#IPS4[@]} 个, IPv6: ${#IPS6[@]} 个"

# 从这里开始装载白名单: 任何一步 iptables 失败都立即中止并大声报错,
# 此时机器处于已清空状态, 需要人工立即重跑本脚本
set -e

# ====================================================================
# 局域网/本机网段白名单（硬编码进脚本, 与 dns.txt 无关, 任何情况下放行）:
#   10.0.0.0/8      10.*.*.*
#   172.17.0.0/16   172.17.*.*（Docker / WSL 内部桥接网络）
#   172.30.1.1/32   WSL NAT 模式默认网关（Windows 宿主机侧）
#   192.168.0.0/16  192.168.*.*
#   127.0.0.0/8     回环（OUTPUT 链同样过滤 lo 接口, 不放行会误杀
#                   本机 127.0.0.1 上的 80/443 服务）
# ====================================================================
LOCAL_NETS4=(
"10.0.0.0/8"
"172.17.0.0/16"
"172.30.1.1/32"
"192.168.0.0/16"
"127.0.0.0/8"
)
LOCAL_NETS6=("::1/128")

# ====================================================================
# 白名单链（不依赖 ipset）: 新白名单先完整建在 <链名>_new 辅助链上，
# 由 iptables-restore 在一个事务里原子装载（链未挂上 OUTPUT 前不参与
# 包匹配），再重建 OUTPUT 挂新链，最后把新链改名为线上名、删除旧链。
# 千余条白名单逐条 -A 要几分钟且中途可见，一次性装载则亚秒完成且无空窗
#   链规则: 已建立连接放行 -> 内网/回环网段放行 -> 白名单 IP 放行
#           -> 其余 80/443 拒绝
#   UDP/443 一并拒绝，否则浏览器对任意网站协商 QUIC 即绕开 HTTPS 白名单
#   IPv6 同构一套，否则有 AAAA 记录的站点走 v6 完全绕过白名单
# ====================================================================

swap_chain() { # swap_chain <iptables命令> <restore命令> <线上链名> <IP数组变量名> <掩码长度> <网段数组变量名>
  local cmd=$1 restore=$2 chain=$3 new=${3}_new old=${3}_old
  local -n ips=$4
  local plen=$5
  local -n nets=$6
  # 清理上次异常中断可能残留的辅助链
  if $cmd -n -L "$new" >/dev/null 2>&1; then $cmd -F "$new"; $cmd -X "$new"; fi
  if $cmd -n -L "$old" >/dev/null 2>&1; then $cmd -F "$old"; $cmd -X "$old"; fi
  {
    printf '*filter\n:%s - [0:0]\n' "$new"
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$new"
    if [ "${#nets[@]}" -gt 0 ]; then
      # 内网/回环网段硬编码放行: 元素自带前缀长度, 不再追加 /plen
      printf -- "-A ${new} -d %s -j ACCEPT\n" "${nets[@]}"
    fi
    if [ "${#ips[@]}" -gt 0 ]; then
      # 固定前缀直接展开进格式串: printf 循环复用格式时逐参数错位是经典坑
      printf -- "-A ${new} -d %s/${plen} -j ACCEPT\n" "${ips[@]}"
    fi
    printf -- '-A %s -p tcp -m multiport --dports 80,443 -j DROP\n' "$new"
    printf -- '-A %s -p udp -m multiport --dports 80,443 -j DROP\n' "$new"
    printf 'COMMIT\n'
  } | $restore -n
  # OUTPUT 链由本脚本全权接管: 先重建好过滤链再清 OUTPUT 挂链，
  # 全开窗口只有两条命令之间的毫秒级
  $cmd -F OUTPUT
  $cmd -A OUTPUT -j "$new"
  # 改名转正: 线上链名保持稳定, 旧链清掉
  if $cmd -n -L "$chain" >/dev/null 2>&1; then
    $cmd -E "$chain" "$old"
  fi
  $cmd -E "$new" "$chain"
  if $cmd -n -L "$old" >/dev/null 2>&1; then
    $cmd -F "$old"
    $cmd -X "$old"
  fi
}

swap_chain iptables iptables-restore DNSFILTER IPS4 32 LOCAL_NETS4
if [ "$HAVE_V6" -eq 1 ]; then
  swap_chain ip6tables ip6tables-restore DNSFILTER6 IPS6 128 LOCAL_NETS6
fi

if [ "$HAVE_V6" -eq 1 ]; then
  echo "[+] 完成: 白名单 IPv4 ${#IPS4[@]} 个 / IPv6 ${#IPS6[@]} 个, 内网网段已放行, 其余 80/443(tcp+udp) 已阻断"
else
  echo "[+] 完成: 白名单 IPv4 ${#IPS4[@]} 个（本机无 IPv6）, 内网网段已放行, 其余 80/443(tcp+udp) 已阻断"
fi
