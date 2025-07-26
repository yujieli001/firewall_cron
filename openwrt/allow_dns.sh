#!/bin/sh

# 获取 dns_sub.txt 的总行数
total=$(wc -l < dns_sub.txt)

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
