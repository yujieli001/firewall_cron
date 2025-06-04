cat > auto_sub_lookup.sh <<'EOF'
#!/bin/sh

DOMAINS="luogu.com.cn
kpcb.org.cn
oj.wlhcode.com
oj.wwwos.net
nbyg.net"

echo "[*] 正在从 crt.sh 获取子域名列表..."

# 清空结果文件
> ipv4.txt
> ipv6.txt

for BASE_DOMAIN in $DOMAINS; do
	# 获取所有包含子域名的字段并提取
	echo ${BASE_DOMAIN}>luogu_subs.txt
	curl -s "https://crt.sh/?q=%25.${BASE_DOMAIN}&output=json"|\
	grep -oE "\"name_value\":\"[^\"]+\"" | \
	sed 's/"name_value":"//;s/"//'|\
	sed 's/\\n/\n/g'|\
	sort -u >>luogu_subs.txt
	total=$(wc -l < luogu_subs.txt)

	echo "[*] 共获取到 $total 个子域名，开始解析 IP..."

	# 遍历子域名解析 IP
	i=0
	while read domain; do
	    i=$((i+1))
		for ip in $(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}'); do
			echo "当前 IP 是：$ip"
			if [ -n "$ip" ]; then
				echo "$domain -> $ip" # | tee -a "$OUT_FILE"
				if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
					echo "$ip" >> ipv4.txt
				elif echo "$ip" | grep -q ':'; then
					echo "$ip" >> ipv6.txt
				fi
			fi   
		done
	done < luogu_subs.txt
done
#sort -u ipv4.txt -o ipv4.txt.tmp && mv ipv4.txt.tmp ipv4.txt
#sort -u ipv6.txt -o ipv6.txt.tmp && mv ipv6.txt.tmp ipv6.txt

echo "[*] 已保存解析结果到 luogu_subs.txt"

EOF
