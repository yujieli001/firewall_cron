#!/bin/sh
# ====================================================================
# openwrt(23.05) 域名白名单解析器: 读取 dns.txt, 解析全部 IPv4/IPv6,
# 生成 /etc/luci-uploads/ipv4.txt 与 ipv6.txt。
# 只生成文件, 不修改防火墙; 拦截仍由 LuCI(firewall4) 建 ipset
# "包括文件"引用这两个 txt + 通信规则实现（见 Readme.md 与截图）。
#
# 文件更新后 ipset 不自动感知。fw4 reload 有约 1~2 秒拦截规则为空的
# 放行窗口, 故脚本仅在文件真正变化时以退出码 10 结束, cron 按需 reload。
# crontab -e（BusyBox crond 开机自启, 改完一分钟内自动生效）追加:
#   */30 * * * * /root/allow_dns.sh >/dev/null 2>&1; [ $? -eq 10 ] && service firewall reload
#   @reboot sleep 30 && { /root/allow_dns.sh >/dev/null 2>&1; [ $? -eq 10 ] && service firewall reload; }
#
# 用法: allow_dns.sh [dns.txt 路径]
#       缺省依次找 /etc/luci-uploads/dns.txt、脚本同目录 dns.txt
# 退出码: 0=成功且文件无变化  10=成功但文件已更新(需 reload)  1=失败(现有文件未动)
# ====================================================================

set -u

PAR=32                                   # DNS 并发查询数(dnsmasq 默认转发上限内; 路由器负载高就调小)
STATE_DIR="${STATE_DIR:-/var/lib/firewall_cron}"   # tmpfs 免每小时磨 flash; 指到 /etc 下可跨重启保留

if [ $# -ge 1 ]; then
  DNS_TXT="$1"
elif [ -f /etc/luci-uploads/dns.txt ]; then
  DNS_TXT=/etc/luci-uploads/dns.txt
else
  DNS_TXT="$(dirname "$0")/dns.txt"
fi

[ "$(id -u)" -eq 0 ] || { echo "[!] 请以 root 运行" >&2; exit 1; }

missing=""
for cmd in nslookup awk sort grep tr cut head wc sleep; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
[ -z "$missing" ] || { echo "[!] 缺少依赖:$missing（定制固件可能裁剪 applet, 需开回）" >&2; exit 1; }

# lihome 等定制固件裁了 timeout applet: 缺失时 DNS 超时走 bg_timeout 兜底,
# 行为等价, 不必告警
HAVE_TIMEOUT=1
command -v timeout >/dev/null 2>&1 || HAVE_TIMEOUT=0

TMPD=$(mktemp -d /tmp/allow_dns.XXXXXX 2>/dev/null) \
  || { TMPD=/tmp/allow_dns.$$; mkdir -p "$TMPD" || exit 1; }
trap 'rm -rf "$TMPD"' EXIT
# 信号 trap 必须先 exit（由 EXIT trap 级联清理）: 只清退不出的话, ^C 之后
# 主体还在已删除的 TMPD 里继续跑, 刷屏 nonexistent directory（实机实测）
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# 常见 DNS 服务器(IP 字面量直接进白名单, 不外发查询)与 DoH 入口(解析后
# 放行其 443, 防白名单掐断自己的 DoH 通道)。多行字符串内不能写行尾 # 注释
DNS_EXTRA="
223.5.5.5
223.6.6.6
119.29.29.29
182.254.116.116
114.114.114.114
114.114.115.115
8.8.8.8
8.8.4.4
1.1.1.1
2400:3200::1
240c::6666
240c::6644
2001:4860:4860::8888
2606:4700:4700::1111
dns.alidns.com
doh.pub
dns.google
cloudflare-dns.com
"

[ -f "$DNS_TXT" ] || { echo "[!] 找不到域名列表（依次试过: 命令行参数、/etc/luci-uploads/dns.txt、脚本同目录 dns.txt）" >&2; exit 1; }
echo "[+] 从 $DNS_TXT 读取域名"

# 列表可能被 Windows 工具改过: 去 CRLF/BOM/#/* 注释/空行, 统一小写。
# 一律用显式字符类而非 [:upper:]/[:space:]: lihome 固件的 tr 有 ctype bug,
# '[:upper:]' 误含小写 p/u 并映射成乱码(实测 openjudge→owenjldge),
# 曾把 600+ 行静默改坏; 显式 A-Z 区间实测正常
tr -d '\r' < "$DNS_TXT" \
  | awk '!/^[#*]/ && !/^[ \t]*$/ {
           if (NR == 1) sub(/^\357\273\277/, "")
           sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
           if (length($0)) print
         }' \
  | tr 'A-Z' 'a-z' | sort -u > "$TMPD/dns_txt"

ndom=$(wc -l < "$TMPD/dns_txt" | tr -d ' ')
[ "$ndom" -gt 0 ] || { echo "[!] 域名列表为空" >&2; exit 1; }
echo "[+] 域名数量: $ndom"

# 域名与硬编码清单合并后按字面量拆三份: IPv4 / IPv6 / 待解析域名
printf '%s\n' "$DNS_EXTRA" | tr 'A-Z' 'a-z' | grep -v '^[ \t]*$' > "$TMPD/extra"
sort -u "$TMPD/dns_txt" "$TMPD/extra" > "$TMPD/all"
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$TMPD/all" > "$TMPD/lit4"
grep -E '^[0-9a-f:]+:[0-9a-f:]+$' "$TMPD/all" > "$TMPD/lit6"
grep -Ev '(^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|:)' "$TMPD/all" > "$TMPD/dom"

# ====================================================================
# 解析 worker: BusyBox nslookup 主机地址行是 "Address␣ip"（空格）, 服务器
# 行是 tab+":53", 按 "^Address: " 取词后再过严格地址正则双保险。
# dns_query: 有 timeout 用它, 没有则 bg_timeout 起睡眠看门狗到点杀进程,
# 命令先结束则反杀看门狗, 不会活到误杀复用的 PID
# ====================================================================
TIMEOUT_S=6

bg_timeout() { # bg_timeout <命令...>: TIMEOUT_S 秒未完就杀掉
  local p w
  "$@" 2>/dev/null & p=$!
  # sleep 的 stdout/stderr 必须挪开: 看门狗继承了调用方的管道写端(本函数
  # 多用于 nslookup|awk 管道及 $(...) 替换), kill 掉看门狗 shell 后其遗孤
  # sleep 仍会握着写端 TIMEOUT_S 秒——下游收不到 EOF 干等, 每次查询都缴一
  # 笔超时税(实机 618 域名因此拖成十几分钟)。重定向后写端随看门狗退出即释
  ( sleep "$TIMEOUT_S" >/dev/null 2>&1; kill "$p" 2>/dev/null ) & w=$!
  wait "$p" 2>/dev/null
  kill "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  return 0
}

if [ "$HAVE_TIMEOUT" -eq 1 ]; then
  dns_query() { timeout "$TIMEOUT_S" "$@" 2>/dev/null; }
else
  dns_query() { bg_timeout "$@"; }
fi

# 提取+校验合并在单个 awk 里(省进程=省 fork, 每轮上千次)
resolve_v4() { # 每行一个 IPv4 输出到 stdout
  dns_query nslookup "$1" \
    | awk '/^Address: / { ip = $2; if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print ip }'
}
resolve_v6() {
  dns_query nslookup -type=AAAA "$1" \
    | awk '/^Address: / { ip = tolower($2); if (ip ~ /^[0-9a-f:]+:[0-9a-f:]+$/) print ip }'
}

# DNS 预检: 解析器整体不可用时快速退出, 不空跑上千次注定失败的查询。
# 两个域名并行查(冷缓存下每个查询都可能一个上游往返, 别排队长串等)
( resolve_v4 baidu.com >"$TMPD/pre1" & resolve_v4 qq.com >"$TMPD/pre2" & wait ) 2>/dev/null
if [ ! -s "$TMPD/pre1" ] && [ ! -s "$TMPD/pre2" ]; then
  echo "[!] DNS 预检失败, 系统解析器不可用, 不改动现有文件" >&2
  exit 1
fi

# 不支持 -type / 本机无 IPv6 / 上游屏蔽某名 AAAA: 双域名并行探测都瞎才
# 判定 v6 不可用并跳过本轮（定时刷新会在恢复后自行补回）
HAVE_AAAA=1
( resolve_v6 dns.google >"$TMPD/aaa1" & resolve_v6 dns.alidns.com >"$TMPD/aaa2" & wait ) 2>/dev/null
if [ ! -s "$TMPD/aaa1" ] && [ ! -s "$TMPD/aaa2" ]; then
  HAVE_AAAA=0
  echo "[!] IPv6 解析不可用, 本次跳过 IPv6 解析" >&2
fi

# 一轮并行解析: 每域名的 v4/v6 查询同时投进同一个并发池(两族分两轮跑,
# 分块等待的"等最慢者"开销直接翻倍, 合并后池子利用率拉满), 每域名每族
# 一个后台子进程写各自小文件, 每凑满 PAR 个查询 wait 一次。按行回收:
# 拿到地址的域名记入 ok 文件, 地址按 "域名<TAB>地址" 进 pairs
probe_round() { # probe_round <域名文件>: 结果写 $TMPD 下 ok4/ok6/pairs4/pairs6
  local nfile=$1 name fam jf i jobs total
  total=$(wc -l < "$nfile" | tr -d ' ')
  i=0; jobs=0
  while read -r name; do
    i=$((i + 1))
    ( resolve_v4 "$name" >"$TMPD/v4.$i" ) 2>/dev/null &
    jobs=$((jobs + 1))
    if [ "$HAVE_AAAA" -eq 1 ]; then
      ( resolve_v6 "$name" >"$TMPD/v6.$i" ) 2>/dev/null &
      jobs=$((jobs + 1))
    fi
    # 进度原地刷新一行(\r): 几百域名解析要几十秒, 全程静默会被当成卡死
    if [ $((jobs % PAR)) -eq 0 ]; then wait; printf '[*] 解析进度: %d/%d\r' "$i" "$total"; fi
  done <"$nfile"
  wait
  printf '[*] 解析进度: %d/%d\n' "$i" "$total"
  i=0
  while read -r name; do
    i=$((i + 1))
    for fam in v4 v6; do
      jf="$TMPD/$fam.$i"
      if [ -s "$jf" ]; then
        if [ "$fam" = v4 ]; then
          echo "$name" >>"$TMPD/ok4"
          awk -v n="$name" '{ print n "\t" $1 }' "$jf" >>"$TMPD/pairs4"
        else
          echo "$name" >>"$TMPD/ok6"
          awk -v n="$name" '{ print n "\t" $1 }' "$jf" >>"$TMPD/pairs6"
        fi
      fi
      rm -f "$jf"
    done
  done <"$nfile"
}

print_sample() { # 失败名单最多列 20 个防刷屏
  head -n 20 "$1"
  [ "$2" -gt 20 ] && echo "    ...（共 $2 个）"
  return 0
}

: >"$TMPD/pairs4"; : >"$TMPD/pairs6"
: >"$TMPD/ok4";    : >"$TMPD/ok6"

probe_round "$TMPD/dom"

# 两个地址族都颗粒无收的域名（并发超时/解析器抖动）重试一次; 单族为空
# 多是本就只有 A 或只有 AAAA 记录, 属正常。ok_any 首行垫空行: 防 NR==FNR
# 惯用法在首个文件为空时把第二个文件首行误判为"已见"
{ echo ""; cat "$TMPD/ok4" "$TMPD/ok6"; } | sort -u > "$TMPD/ok_any"
awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' "$TMPD/ok_any" "$TMPD/dom" > "$TMPD/pending"

fail_after_retry=0
pn=$(wc -l < "$TMPD/pending" | tr -d ' ')
if [ "$pn" -gt 0 ]; then
  echo "[+] 首轮 $pn 个域名未解析到任何地址, 重试一次:"
  print_sample "$TMPD/pending" "$pn"
  probe_round "$TMPD/pending"
  { echo ""; cat "$TMPD/ok4" "$TMPD/ok6"; } | sort -u > "$TMPD/ok_any"
  awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' "$TMPD/ok_any" "$TMPD/pending" > "$TMPD/stillfail"
  fail_after_retry=$(wc -l < "$TMPD/stillfail" | tr -d ' ')
  if [ "$fail_after_retry" -gt 0 ]; then
    echo "[!] 以下 $fail_after_retry 个域名重试后仍解析失败, 本次不会进白名单:" >&2
    print_sample "$TMPD/stillfail" "$fail_after_retry"
  else
    echo "[+] 重试后全部解析成功"
  fi
fi

# 本轮地址集合: 解析结果 + IP 字面量, 再过一遍格式正则并去重
{ cut -f2 "$TMPD/pairs4"; cat "$TMPD/lit4"; } \
  | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' | sort -u > "$TMPD/run4"
{ cut -f2 "$TMPD/pairs6"; cat "$TMPD/lit6"; } \
  | awk '/^[0-9a-f:]+:[0-9a-f:]+$/' | sort -u > "$TMPD/run6"

# ====================================================================
# 增量累积: 白名单只增不减, 输出 历史 ∪ 本轮。CDN 对同一域名做 DNS 轮询,
# 单次查询只返回地址池一个子集, 定时刷新才把池子逐步攒全。
# 代价是放行面单调扩大（云厂商会回收再分配地址）, 想收敛就删状态文件重跑。
# 历史文件逐行校验格式防脏行混入; 正则写进 awk 程序文本（-v 赋值会先转义,
# \. 会被吃掉）。merged ⊇ hist 恒成立, 写回永不丢历史
# ====================================================================
STATE4="$STATE_DIR/whitelist4.txt"
STATE6="$STATE_DIR/whitelist6.txt"
mkdir -p "$STATE_DIR" || { echo "[!] 无法创建状态目录 $STATE_DIR" >&2; exit 1; }

for f in 4 6; do
  if [ "$f" = 4 ]; then state="$STATE4"; else state="$STATE6"; fi
  : >"$TMPD/hist$f"
  if [ "$f" = 4 ]; then
    [ -f "$state" ] && awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' "$state" | sort -u > "$TMPD/hist$f"
  else
    [ -f "$state" ] && awk '/^[0-9a-f:]+:[0-9a-f:]+$/' "$state" | sort -u > "$TMPD/hist$f"
  fi
  cat "$TMPD/hist$f" "$TMPD/run$f" | sort -u > "$TMPD/merged$f"
  # 写回原子 mv; tmp 不在 $TMPD 里, 失败要自己清（trap 够不着）。
  # 两实例交叠(mv 原子)与断电都只可能退回旧集合或前进, 不会写出半截文件
  { cat "$TMPD/merged$f" >"$state.tmp.$$" && mv -f "$state.tmp.$$" "$state"; } \
    || rm -f "$state.tmp.$$"
done

hist4=$(wc -l < "$TMPD/hist4" | tr -d ' ')
hist6=$(wc -l < "$TMPD/hist6" | tr -d ' ')
ips4=$(wc -l < "$TMPD/merged4" | tr -d ' ')
ips6=$(wc -l < "$TMPD/merged6" | tr -d ' ')
# merged 是 hist∪run 去重并集, hist 必为其子集, 新增数 = 行数直减
# （不用 comm: 它也是常被定制固件裁掉的 applet）
echo "[+] IPv4: 历史 ${hist4} + 新增 $((ips4 - hist4)) = ${ips4} 个"
echo "[+] IPv6: 历史 ${hist6} + 新增 $((ips6 - hist6)) = ${ips6} 个, 重试后仍失败: ${fail_after_retry} 个"

# ====================================================================
# 输出唯一交付物 ipv4.txt / ipv6.txt。内容没变化就不重写（文件在 flash 上,
# 半小时全量重写白耗写入寿命）; 重写即有变化, 退出码 10 通知 cron reload
# ====================================================================
OUT_DIR=/etc/luci-uploads
mkdir -p "$OUT_DIR" || { echo "[!] 无法创建输出目录 $OUT_DIR" >&2; exit 1; }
CHANGED=0
write_if_changed() { # write_if_changed <源> <目标>: 内容相同则跳过
  # 不用 cmp 比对（又一个常被裁的 applet）; 行式文本字符串比较即可,
  # 命令替换剥尾换行无害——两份 IP 列表的差异不会只在尾换行
  if [ -f "$2" ] && [ "$(cat "$1")" = "$(cat "$2")" ]; then return 0; fi
  cat "$1" > "$2" || return 1
  CHANGED=1
  return 0
}
if write_if_changed "$TMPD/merged4" "$OUT_DIR/ipv4.txt" \
   && write_if_changed "$TMPD/merged6" "$OUT_DIR/ipv6.txt"; then
  echo "[+] ipv4.txt（$ips4 个）与 ipv6.txt（$ips6 个）已在 $OUT_DIR/ 就位"
else
  echo "[!] ipv4.txt/ipv6.txt 写入 $OUT_DIR/ 失败" >&2
  exit 1
fi
if [ "$CHANGED" -eq 1 ]; then
  echo "[*] 文件有更新, 需 service firewall reload 让 ipset 重新装载（退出码 10）"
  exit 10
fi
