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
#
# 解析结果按 "域名<TAB>地址" 回流而非只回流地址: 保住名字与地址的对应
# 关系, 事后才知道哪些域名一个地址都没拿到。P16 并发下 getent 偶发超时
# 会让个别域名静默丢失（本机 DNS 中继在高并发下会卡即是同类问题）, 这类
# 域名重试一轮, 尽力保证 dns.txt 每个域名都进白名单。
# "解析失败" 判定为两个地址族都拿不到合法地址: 仅单族为空多半是域名本身
# 只有 A 或只有 AAAA 记录, 属正常而非故障, 不重试, 免得为单族缺失把
# 防火墙空窗期拉长一倍。重试后仍失败的域名只大声告警不中止——它们多数
# 是已经关站死掉的域名, 且此刻旧规则已清空, 中止等于整机裸奔。
# ====================================================================

# DNS 预检: 解析器整体不可用时快速退出保持旧规则, 不空跑上千次注定失败的查询
if ! timeout 5 getent ahostsv4 baidu.com >/dev/null 2>&1 \
   && ! timeout 5 getent ahostsv4 qq.com >/dev/null 2>&1; then
  echo "[!] DNS 预检失败, 系统解析器不可用, 保持现有规则不变" >&2
  exit 1
fi

# 单域名解析 worker, 由 xargs 经 bash -c 调起, 故必须 export -f 才能被子
# bash 从环境里导入。成功时每个地址输出一行 "域名<TAB>地址"; 解析失败或
# 该族无记录时静默无输出, 由上层按名字聚合后判定是否需要重试。
resolve_one() { # resolve_one <ahostsv4|ahostsv6> <域名>
  local family=$1 name=$2 out addr
  out=$(timeout 5 getent "$family" "$name" 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  while read -r addr; do
    [ -n "$addr" ] && printf '%s\t%s\n' "$name" "${addr%% *}"
  done <<<"$out"
  return 0
}
export -f resolve_one

# 一轮并行解析: 从参数读域名, 输出通过地址格式校验的 "域名<TAB>地址"。
# 域名经 bash -c 落到 $0（xargs 把输入项追加为 bash 的首个位置参数）,
# 全程带引号, 不会二次展开。
probe_round() { # probe_round <地址族> <合法地址awk正则> <域名...>
  local family=$1 regex=$2
  shift 2
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$@" \
    | xargs -r -P 16 -n 1 bash -c "resolve_one $family \"\$0\"" 2>/dev/null \
    | awk -F'\t' -v re="$regex" '$2 ~ re'
}

# awk 的 -v 赋值会先做一遍转义处理, 故正则里的 \. 在此要写成 \\.
RE_ADDR4='^([0-9]{1,3}\\.){3}[0-9]{1,3}$'
RE_ADDR6='^[0-9A-Fa-f:]+:[0-9A-Fa-f:]+$'

# ====================================================================
# 先清空防火墙全部原有规则, 再由本脚本从零装载白名单:
# filter 表内置链策略恢复 ACCEPT 后整表清空、删除自定义链,
# nat/mangle 等表存在则一并清（会连带清掉 ufw/docker 等的规则）; IPv4/IPv6 各一遍。
# 先改策略后清规则, 顺序不可反: 若旧策略是 DROP, 先清规则会瞬间锁死整机。
# 从此刻到白名单链挂上, 过滤规则为空——列表检查与 DNS 预检已在前面完成,
# 该窗口通常只有解析所用的几秒。iptables 规则每次都是重建的, 但白名单地址
# 不会丢: 历次解析结果累积在 $STATE_DIR, 本轮解析不出东西时退回历史集合
# 装载; 只有"本轮 + 历史"双双为空才会带着空规则集退出（需人工重跑）
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

ALL_NAMES=( "${domains[@]}" "${DNS_SERVERS[@]}" "${DNS_DOMAINS[@]}" )

# 本轮解析结果: 地址去重与"已拿到地址的域名"集合, 关联数组键天然去重
declare -A RUN4=() RUN6=() OK_NAME=()

collect_pairs() { # collect_pairs <v4|v6> <"域名<TAB>地址"...>
  local fam=$1 pair name addr
  shift
  for pair in "$@"; do
    # 防御: 没有 TAB 或字段为空的畸形行跳过。正常路径已被 probe_round 的
    # 格式校验拦下, 这里只兜底, 免得给关联数组塞进空下标
    case $pair in
      *$'\t'*) ;;
      *) continue ;;
    esac
    name=${pair%%$'\t'*}
    addr=${pair#*$'\t'}
    { [ -n "$name" ] && [ -n "$addr" ]; } || continue
    addr=${addr,,}                  # 统一小写: 同一 IPv6 不因大小写差异重复入库
    if [ "$fam" = v4 ]; then RUN4["$addr"]=1; else RUN6["$addr"]=1; fi
    OK_NAME["$name"]=1
  done
}

print_sample() { # print_sample <域名...>: 失败名单可能几百个, 最多列 20 个防刷屏
  local arr=( "$@" ) n=${#arr[@]} lim=20 i
  (( n < lim )) && lim=$n
  for (( i = 0; i < lim; i++ )); do echo "    ${arr[$i]}" >&2; done
  if (( n > lim )); then echo "    ...（共 $n 个）" >&2; fi
}

mapfile -t PAIRS4 < <(probe_round ahostsv4 "$RE_ADDR4" "${ALL_NAMES[@]}")
mapfile -t PAIRS6 < <(probe_round ahostsv6 "$RE_ADDR6" "${ALL_NAMES[@]}")
collect_pairs v4 "${PAIRS4[@]}"
collect_pairs v6 "${PAIRS6[@]}"

# 首轮两个地址族都颗粒无收的域名: 并发超时/解析器抖动的典型症状, 重试一次
pending=()
for name in "${ALL_NAMES[@]}"; do
  [ "${OK_NAME[$name]+x}" ] || pending+=("$name")
done

RETRY_FAILED=()
if [ "${#pending[@]}" -gt 0 ]; then
  echo "[+] 首轮 ${#pending[@]} 个域名未解析到任何地址, 重试一次:"
  print_sample "${pending[@]}"
  mapfile -t PAIRS4 < <(probe_round ahostsv4 "$RE_ADDR4" "${pending[@]}")
  mapfile -t PAIRS6 < <(probe_round ahostsv6 "$RE_ADDR6" "${pending[@]}")
  collect_pairs v4 "${PAIRS4[@]}"
  collect_pairs v6 "${PAIRS6[@]}"
  for name in "${pending[@]}"; do
    [ "${OK_NAME[$name]+x}" ] || RETRY_FAILED+=("$name")
  done
  if [ "${#RETRY_FAILED[@]}" -gt 0 ]; then
    echo "[!] 以下 ${#RETRY_FAILED[@]} 个域名重试后仍解析失败, 本次不会进白名单:" >&2
    print_sample "${RETRY_FAILED[@]}"
  else
    echo "[+] 重试后全部解析成功"
  fi
fi

# ====================================================================
# 增量累积: 白名单只增不减, 装载 历史 ∪ 本轮
#   CDN/云厂商对同一域名做 DNS 轮询, 单次查询只返回地址池里的一个子集
#   （实测 65 秒内就有约 100/637 个域名换了地址集合）。只装单次快照必然
#   漏掉池子其余部分, 表现为"上一秒还能访问, 刷新后就断"。历次运行解析到
#   的地址全部保留并去重, 池子会被逐步覆盖全。
#   历史存在 $STATE_DIR（可用同名环境变量改写, 便于测试）, 与 iptables
#   解耦: WSL 重启、规则被清空都不丢; 顺带让 DNS 整体故障时还能退回历史
#   集合装载, 而不是带着空规则集裸奔。
#   代价是放行面单调扩大: 云厂商会回收再分配地址, 攒久了等于顺带放行别
#   人新上线的站点。想收敛就直接删掉状态文件重跑一次, 重新开始累积。
# ====================================================================
STATE_DIR="${STATE_DIR:-/var/lib/firewall_cron}"
STATE4="$STATE_DIR/whitelist4.txt"
STATE6="$STATE_DIR/whitelist6.txt"

load_state() { # load_state <状态文件> <目标关联数组名> <awk地址正则>
  local file=$1 line
  local -n dest=$2
  local regex=$3
  [ -f "$file" ] || return 0
  # 边读边做格式校验: 文件被手工编辑过或写坏时, 脏行不会混进规则
  while IFS= read -r line; do
    dest["$line"]=1
  done < <(awk -v re="$regex" '$1 ~ re {print tolower($1)}' "$file")
  return 0
}

save_state() { # save_state <状态文件> <来源关联数组名>
  local file=$1 tmp
  local -n src=$2
  # 空集合绝不覆盖已有历史: 一次解析失败不该把历次累积的成果清零
  [ "${#src[@]}" -gt 0 ] || return 0
  mkdir -p "$STATE_DIR"
  tmp="${file}.tmp.$$"
  printf '%s\n' "${!src[@]}" >"$tmp"
  mv -f "$tmp" "$file"          # 先写临时文件再改名, 中途断电不会毁掉旧历史
}

declare -A ACC4=() ACC6=()
load_state "$STATE4" ACC4 "$RE_ADDR4"
load_state "$STATE6" ACC6 "$RE_ADDR6"
HIST4=${#ACC4[@]}
HIST6=${#ACC6[@]}

ADDED4=0
for ip in "${!RUN4[@]}"; do [ "${ACC4[$ip]+x}" ] || ADDED4=$((ADDED4 + 1)); done
ADDED6=0
for ip in "${!RUN6[@]}"; do [ "${ACC6[$ip]+x}" ] || ADDED6=$((ADDED6 + 1)); done

for ip in "${!RUN4[@]}"; do ACC4["$ip"]=1; done
for ip in "${!RUN6[@]}"; do ACC6["$ip"]=1; done

IPS4=( "${!ACC4[@]}" )
IPS6=( "${!ACC6[@]}" )

save_state "$STATE4" ACC4
save_state "$STATE6" ACC6

# 本轮颗粒无收但历史仍在: 用历史集合继续装载, 比空规则集安全得多
if [ "${#RUN4[@]}" -eq 0 ] && [ "${#IPS4[@]}" -gt 0 ]; then
  echo "[!] 本轮未解析到任何 IPv4, 退回历史累积的 ${#IPS4[@]} 个地址装载" >&2
fi

# 本轮与历史都为空才真的没法装载。注意此刻旧规则已被清空, 必须修复后重跑
if [ "${#IPS4[@]}" -eq 0 ]; then
  echo "[!] 本轮与历史都没有任何 IPv4 地址, 无法装载白名单; 原有规则已被清空, 请立即重跑本脚本" >&2
  exit 1
fi

echo "[+] IPv4: 历史 ${HIST4} + 新增 ${ADDED4} = ${#IPS4[@]} 个"
echo "[+] IPv6: 历史 ${HIST6} + 新增 ${ADDED6} = ${#IPS6[@]} 个, 重试后仍失败: ${#RETRY_FAILED[@]} 个"

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
