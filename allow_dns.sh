#!/bin/sh

DNS=/etc/luci-uploads/dns_sub.txt
IPV4=/etc/luci-uploads/ipv4.txt
IPV6=/etc/luci-uploads/ipv6.txt

> $IPV4
> $IPV6

total=$(wc -l < $DNS)

i=0
while read domain
do
    i=$((i+1))

    ips=$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}' | sort -u)

    if [ -z "$ips" ]; then
        echo "[$i/$total] $domain 解析失败"
        continue
    fi

    for ip in $ips
    do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        then
            echo "$ip" >> $IPV4
        elif echo "$ip" | grep -q ':'
        then
            echo "$ip" >> $IPV6
        fi
    done

    echo "[$i/$total] $domain 解析完成"

done < $DNS

sort -u $IPV4 -o $IPV4
sort -u $IPV6 -o $IPV6

echo "IPv4 数量: $(wc -l < $IPV4)"
echo "IPv6 数量: $(wc -l < $IPV6)"
