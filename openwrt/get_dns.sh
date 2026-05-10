#!/bin/sh

OUT="/etc/luci-uploads/dns_sub.txt"
TMP_FILE="/tmp/dns_sub.tmp"

# 固定域名列表
DOMAINS="
luogu.com.cn
kpcb.org.cn
ccf.org.cn
iai.sh.cn
atcoder.jp
acmcoder.com
oss-cn-hangzhou.aliyuncs.com
lanqiaoqingshao.cn
alicdn.com
gvt2.com
gcp.gvt2.com
vjudge.net
"

# 创建目录
mkdir -p /etc/luci-uploads
> "$OUT"

echo "[*] 写入固定域名..."

cat <<EOF >> "$OUT"
edge.microsoft.com
oj.wwwos.net
oj.wlhcode.com
cdn.wlhcode.com
ygoj.wwwos.net
gesp.ccf.org.cn
www.iai.sh.cn
ceic.kpcb.org.cn
www.lanqiaoqingshao.cn
api.lanqiaoqingshao.cn
oss.lanqiaoqingshao.cn
oss.stem86.com
vjudge.net
o.alicdn.com
g.alicdn.com
at.alicdn.com
img.atcoder.jp
cdn.jsdelivr.net
fonts.gstatic.com
fonts.googleapis.com
www.google-analytics.com
www.googletagmanager.com
EOF

echo "[*] 从 crt.sh 获取子域名..."

for DOMAIN in $DOMAINS
do
    echo "[*] $DOMAIN"
    curl -s "https://crt.sh/?q=%25.${DOMAIN}&output=json" \
        | grep -oE '"name_value":"[^"]+"' \
        | sed 's/"name_value":"//;s/"//' \
        | sed 's/\\n/\n/g' \
        | grep -v '^\*\.' >> "$OUT"
done

echo "[*] 去重中..."

# 使用 awk 保持顺序去重
awk '!seen[$0]++' "$OUT" > "$TMP_FILE" && mv "$TMP_FILE" "$OUT"

echo "[✔] 完成，共 $(wc -l < "$OUT") 个子域名"
