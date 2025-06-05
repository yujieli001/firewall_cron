cat > auto_sub_lookup.sh <<'EOF'
#!/bin/sh

# 主域名
DOMAINS="
luogu.com.cn
kpcb.org.cn
ccf.org.cn"

# 创建输出目录并清空上次结果
mkdir -p /etc/luci-uploads
> dns_sub.txt
> /etc/luci-uploads/ipv4.txt
> /etc/luci-uploads/ipv6.txt

# 强制添加的子域名
cat <<EOF2 >> dns_sub.txt
oj.wwwos.net
oj.wlhcode.com
ygoj.wwwos.net
wp.wwwos.net
gesp.ccf.org.cn
ceic.kpcb.org.cn
g.alicdn.com
EOF2

echo "[*] 开始从 crt.sh 获取多个域名的子域名并解析 IP ..."

for DOMAIN in $DOMAINS; do
    echo $DOMAIN >> dns_sub.txt
    echo "[*] 获取 ${DOMAIN} 的子域名列表..."

    # 获取 crt.sh 的 JSON 内容
    RESP=$(curl -s --max-time 10 "https://crt.sh/?q=%25.${DOMAIN}&output=json")
    if [ -z "$RESP" ]; then
        echo "[-] 获取 $DOMAIN 子域名失败，跳过..."
        continue
    fi

    echo "$RESP" | grep -oE '"name_value":"[^"]+"' | \
        sed 's/"name_value":"//;s/"//' | \
        sed 's/\\n/\n/g' >> dns_sub.txt
done

# 去重子域名
sort -u dns_sub.txt > /tmp/dns_sub_tmp.txt && mv /tmp/dns_sub_tmp.txt dns_sub.txt

total=$(wc -l < dns_sub.txt)
echo "[*] 共获取到 $total 个子域名，开始解析 IP ..."

i=0
while read domain; do
    i=$((i+1))
    for ip in $(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}'); do
        if [ -n "$ip" ]; then
            if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "$ip" >> /etc/luci-uploads/ipv4.txt
            elif echo "$ip" | grep -q ':'; then
                echo "$ip" >> /etc/luci-uploads/ipv6.txt
            fi
        fi
    done
    echo "    [$i/$total] $domain 解析完毕"
    sleep 1
done < dns_sub.txt

sort -u /etc/luci-uploads/ipv4.txt > /tmp/ipv4_tmp.txt && mv /tmp/ipv4_tmp.txt /etc/luci-uploads/ipv4.txt
sort -u /etc/luci-uploads/ipv6.txt > /tmp/ipv6_tmp.txt && mv /tmp/ipv6_tmp.txt /etc/luci-uploads/ipv6.txt

EOF
