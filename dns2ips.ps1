# ================================================
# 文件路径说明（可根据实际情况修改）：
#   子域名列表:    ./dns_sub.txt
#   IPv4 输出:     ./ipv4.txt
#   IPv6 输出:     ./ipv6.txt
# ================================================

# 1. 定义主域名数组
$DOMAINS = @(
    "luogu.com.cn",
    "iai.sh.cn",
    "atcoder.jp",
    "kpcb.org.cn",
    "ccf.org.cn",
    "oss-cn-hangzhou.aliyuncs.com",
    "lanqiaoqingshao.cn",
    "alicdn.com"
)

# 2. 初始化输出目录 + 清空上次结果

# 清空（或创建）dns_sub.txt、ipv4.txt、ipv6.txt
$dnsFile   = "dns_sub.txt"
$ipv4File  = "ipv4.txt"
$ipv6File  = "ipv6.txt"

# 用空内容覆盖，若不存在则自动创建空文件
Set-Content -Path $dnsFile  -Value $null
Set-Content -Path $ipv4File -Value $null
Set-Content -Path $ipv6File -Value $null

# 3. 强制添加的子域名（与 shell 脚本保持一致）
$forcedSubs = @(
    "edge.microsoft.com",
    "codeds.xueersi.com",
    "vpn.nbyg.net", 
    "www.iai.sh.cn",
    "atcoder.jp",
    "img.atcoder.jp",
    "cdn.d2-apps.net",
    "cdn.jsdelivr.net",
    "static.addtoany.com",
    "fonts.gstatic.com",
    "fonts.googleapis.com",
    "www.google-analytics.com",
    "www.googletagmanager.com",
    "challenges.cloudflare.com",
    "zhongshi-files.oss-cn-zhangjiakou.aliyuncs.com",
    "yacs-public.oss-cn-hangzhou.aliyuncs.com",
    "acdn-world.luogu.com.cn",
    "adl.ccf.org.cn",
    "bsxt.kpcb.org.cn",
    "ccf.org.cn",
    "cdn.class.luogu.com.cn",
    "cdn.luogu.com.cn",
    "ceic.kpcb.org.cn",
    "class.luogu.com.cn",
    "cncc.ccf.org.cn",
    "cncc2018.ccf.org.cn",
    "conf.ccf.org.cn",
    "conf2.ccf.org.cn",
    "csp.ccf.org.cn",
    "cyeiic.kpcb.org.cn",
    "dati.kpcb.org.cn",
    "dewebug.luogu.com.cn",
    "dl.ccf.org.cn",
    "ecfinal.luogu.com.cn",
    "errtrack.luogu.com.cn",
    "fces.ccf.org.cn",
    "fecdn.luogu.com.cn",
    "g.alicdn.com",
    "o.alicdn.com",
    "at.alicdn.com",
    "aeis.alicdn.com",
    "gesp.ccf.org.cn",
    "help.luogu.com.cn",
    "hhme.ccf.org.cn",
    "icpc.luogu.com.cn",
    "ipic.luogu.com.cn",
    "jingsai.kpcb.org.cn",
    "kpcb.org.cn",
    "luogu.com.cn",
    "mobile.ccf.org.cn",
    "oa.ccf.org.cn",
    "oj.wlhcode.com",
    "oj.wwwos.net",
    "online.ccf.org.cn",
    "passport.ccf.org.cn",
    "payment.luogu.com.cn",
    "serviceprod.kpcb.org.cn",
    "sso.ccf.org.cn",
    "stream.class.luogu.com.cn",
    "stream-push.class.luogu.com.cn",
    "stream-rts.class.luogu.com.cn",
    "tf.ccf.org.cn",
    "ti.luogu.com.cn",
    "video.class.luogu.com.cn",
    "web.ccf.org.cn",
    "wp.wwwos.net",
    "ws.class.luogu.com.cn",
    "ws.luogu.com.cn",
    "api.tsinghuax.com",
    "www.ccf.org.cn",
    "www.kpcb.org.cn",
    "www.luogu.com.cn",
    "ygoj.wwwos.net",
    "comp.webtrncdn.com",
    "www.lanqiaoqingshao.cn",
    "api.lanqiaoqingshao.cn",
    "oss.lanqiaoqingshao.cn",
    "ynuf.aliapp.org",
    "gm.mmstat.com",
    "oss.stem86.com"
)
# 将强制子域名写入 dns_sub.txt
$forcedSubs | ForEach-Object { Add-Content -Path $dnsFile -Value $_ }

Write-Host "[*] 已写入强制子域名，共计 $($forcedSubs.Count) 条。"

# 4. 从 crt.sh 拉取并收集所有子域名，存入 HashSet 做去重
$allSubdomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 4.1 先把强制子域名加入 HashSet
foreach ($sub in $forcedSubs) {
    [void]$allSubdomains.Add($sub)
}

# 4.2 遍历主域名，从 crt.sh 拉取 JSON 并提取子域名
foreach ($base in $DOMAINS) {
    Write-Host "[*] 获取 $base 的子域名列表..."
    $url = "https://crt.sh/?q=%25.$base&output=json"

    try {
        # --max-time 等价参数：-TimeoutSec
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop

        # response 是一个对象数组，属性名是 name_value
        foreach ($entry in $response) {
            if ($null -ne $entry.name_value) {
                # name_value 里可能包含多行，以换行分隔
                $subs = $entry.name_value -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                foreach ($sub in $subs) {
                    [void]$allSubdomains.Add($sub)
                }
            }
        }
    }
    catch {
        Write-Host "[-] 获取 $base 子域名失败，跳过。错误： $_"
    }
}

# 4.3 还需把主域名本身也加到集合里（与 shell 脚本逻辑保持一致）
foreach ($d in $DOMAINS) {
    [void]$allSubdomains.Add($d)
}

# 5. 将去重后的子域名全部写回 dns_sub.txt，并排序
#    先清空，然后写入排序后的所有子域名
Set-Content -Path $dnsFile -Value $null
$allSubdomains  `
    | Sort-Object `
    | ForEach-Object { Add-Content -Path $dnsFile -Value $_ }

$total = $allSubdomains.Count
Write-Host "[*] 共获取到 $total 个子域名，已写入 $dnsFile。"

# 6. 逐个解析每个子域名，区分 IPv4/IPv6 写入不同文件
$i = 0
foreach ($domain in $allSubdomains) {
    $i++
    if (![string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "    [$i/$total] 正在解析 $domain ..."
        try {
            # GetHostAddresses 会返回 IPv4 和 IPv6 地址对象
            $addresses = [System.Net.Dns]::GetHostAddresses($domain) `
                         | Select-Object -ExpandProperty IPAddressToString
            foreach ($ip in $addresses) {
                try {
                    $addrObj = [System.Net.IPAddress]::Parse($ip)
                    switch ($addrObj.AddressFamily) {
                        "InterNetwork" {
                            Add-Content -Path $ipv4File -Value $ip
                        }
                        "InterNetworkV6" {
                            Add-Content -Path $ipv6File -Value $ip
                        }
                        default {
                            # 其他类型暂不处理
                        }
                    }
                }
                catch {
                    # 非法 IP 字符串，忽略
                }
            }
        }
        catch {
            Write-Host "    [!] 解析失败： $domain"
        }
    }
}

# 7. 对 ipv4.txt、ipv6.txt 再次去重 + 排序
if (Test-Path $ipv4File) {
    Get-Content -Path $ipv4File         `
        | Sort-Object -Unique           `
        | Set-Content -Path $ipv4File
} else {
    Set-Content -Path $ipv4File -Value $null
}

if (Test-Path $ipv6File) {
    Get-Content -Path $ipv6File         `
        | Sort-Object -Unique           `
        | Set-Content -Path $ipv6File
} else {
    Set-Content -Path $ipv6File -Value $null
}

# 8. 输出最终结果数量
$ipv4Count = 0
$ipv6Count = 0
if (Test-Path $ipv4File) {
    $ipv4Count = (Get-Content $ipv4File | Measure-Object).Count
}
if (Test-Path $ipv6File) {
    $ipv6Count = (Get-Content $ipv6File | Measure-Object).Count
}

Write-Host "[*] 操作完成！"
Write-Host "[*] IPv4 地址数量: $ipv4Count"
Write-Host "[*] IPv6 地址数量: $ipv6Count"
