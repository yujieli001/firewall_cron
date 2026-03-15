#!/bin/sh

OUT=/etc/luci-uploads/dns_sub.txt

DOMAINS="
luogu.com.cn
kpcb.org.cn
ccf.org.cn
ai.sh.cn
atcoder.jp
acmcoder.com
oss-cn-hangzhou.aliyuncs.com
lanqiaoqingshao.cn
alicdn.com
gvt2.com
gcp.gvt2.com
"

mkdir -p /etc/luci-uploads
> $OUT

echo "[*] 写入固定域名..."

cat <<EOF >> $OUT
edge.microsoft.com
oj.wwwos.net
oj.wlhcode.com
ygoj.wwwos.net
wp.wwwos.net
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
    | grep -v '^\*\.' >> $OUT

done

sort -u $OUT -o $OUT

echo "[✔] 完成，共 $(wc -l < $OUT) 个子域名"
