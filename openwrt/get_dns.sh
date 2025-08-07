#!/bin/sh

# 主域名
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
    gcp.gvt2.com"

# 创建输出目录并清空上次结果
mkdir -p /etc/luci-uploads
> dns_sub.txt

# 强制添加的子域名
cat <<EOF2 >> dns_sub.txt
a.w9.ip-ddns.com
edge.microsoft.com
oj.wwwos.net
oj.wlhcode.com
ygoj.wwwos.net
wp.wwwos.net
atcoder.jp
img.atcoder.jp
cdn.d2-apps.net
cdn.jsdelivr.net
static.addtoany.com
fonts.gstatic.com
fonts.googleapis.com
www.google-analytics.com
www.googletagmanager.com
gesp.ccf.org.cn
ceic.kpcb.org.cn
g.alicdn.com
o.alicdn.com
at.alicdn.com
aeis.alicdn.com
comp.webtrncdn.com
api.tsinghuax.com
www.iai.sh.cn
vpn.nbyg.net
yacs-public.oss-cn-hangzhou.aliyuncs.com
zhongshi-files.oss-cn-zhangjiakou.aliyuncs.com
luogu.com.cn
www.luogu.com.cn
acdn-world.luogu.com.cn
cdn.class.luogu.com.cn
cdn.luogu.com.cn
class.luogu.com.cn
dewebug.luogu.com.cn
ecfinal.luogu.com.cn
errtrack.luogu.com.cn
fecdn.luogu.com.cn
help.luogu.com.cn
icpc.luogu.com.cn
ipic.luogu.com.cn
payment.luogu.com.cn
stream-push.class.luogu.com.cn
stream-rts.class.luogu.com.cn
stream.class.luogu.com.cn
ti.luogu.com.cn
video.class.luogu.com.cn
ws.class.luogu.com.cn
ws.luogu.com.cn
passport.ccf.org.cn
www.lanqiaoqingshao.cn
api.lanqiaoqingshao.cn
oss.lanqiaoqingshao.cn
ynuf.aliapp.org
gm.mmstat.com
oss.stem86.com
a.w9.ip-ddns.com
crt.sh
open.bigmodel.cn
analytics.immersivetranslate.com
beacons.gcp.gvt2.com
beacons.gvt2.com
b1.nel.goog
e2c35.gcp.gvt2.com
examacmcoder.oss-cn-beijing.aliyuncs.com
examacmcoder.oss-accelerate.aliyuncs.com
acmcoder.com
lanqiao.acmcoder.com
ws.acmcoder.com
tcdn.acmcoder.com
62885.acmcoder.com
all.acmcoder.com.w.kunlunsl.com
alb-cz0efer2d8r287ath9.cn-beijing.alb.aliyuncs.com
exam.acmcoder.com
exercise.acmcoder.com
pel9t1l49r4hy553.aliyunddos1013.com
labfiles.acmcoder.com.w.cdngslb.com
088bxw1q70s5dsjk.aliyunddos1013.com
51b9047024eu1o81.aliyunddos1013.com
7q2c176p6t5vh87n.aliyunddos1013.com
examassets.acmcoder.com
cdnw2.acmcoder.com
EOF2

echo "[*] 开始从 crt.sh 获取多个域名的子域名并解析 IP ..."

for DOMAIN in $DOMAINS; do
    echo $DOMAIN >> dns_sub.txt
    echo "[*] 获取 ${DOMAIN} 的子域名列表..."

    # 获取 crt.sh 的 JSON 内容并过滤 *. 开头的泛域名
    RESP=$(curl -s --max-time 10 "https://crt.sh/?q=%25.${DOMAIN}&output=json")
    if [ -z "$RESP" ]; then
        echo "[-] 获取 $DOMAIN 子域名失败，跳过..."
        continue
    fi

    echo "$RESP" | grep -oE '"name_value":"[^"]+"' | \
        sed 's/"name_value":"//;s/"//' | \
        sed 's/\\n/\n/g' | \
        grep -v '^\*\.' >> dns_sub.txt
done

# 去重子域名
sort -u dns_sub.txt > /tmp/dns_sub_tmp.txt && mv /tmp/dns_sub_tmp.txt dns_sub.txt

echo "[✔] 子域名收集完毕，共 $(wc -l < dns_sub.txt) 个"
