# get_dns.ps1 - 仅收集非 * 开头的子域名，写入 dns_sub.txt
$dnsFile = "dns_sub.txt"
$domains = @(
    "luogu.com.cn", "iai.sh.cn", "atcoder.jp", "kpcb.org.cn", "ccf.org.cn",
    "oss-cn-hangzhou.aliyuncs.com", "lanqiaoqingshao.cn", "alicdn.com"
)
$forcedSubs = @(
    "edge.microsoft.com", "codeds.xueersi.com", "vpn.nbyg.net", "www.iai.sh.cn", "atcoder.jp",
    "img.atcoder.jp", "cdn.d2-apps.net", "cdn.jsdelivr.net", "static.addtoany.com",
    "fonts.gstatic.com", "fonts.googleapis.com", "www.google-analytics.com", "www.googletagmanager.com",
    "challenges.cloudflare.com", "zhongshi-files.oss-cn-zhangjiakou.aliyuncs.com",
    "yacs-public.oss-cn-hangzhou.aliyuncs.com", "acdn-world.luogu.com.cn", "adl.ccf.org.cn",
    "bsxt.kpcb.org.cn", "ccf.org.cn", "cdn.class.luogu.com.cn", "cdn.luogu.com.cn", "ceic.kpcb.org.cn",
    "class.luogu.com.cn", "cncc.ccf.org.cn", "cncc2018.ccf.org.cn", "conf.ccf.org.cn",
    "conf2.ccf.org.cn", "csp.ccf.org.cn", "cyeiic.kpcb.org.cn", "dati.kpcb.org.cn", "dewebug.luogu.com.cn",
    "dl.ccf.org.cn", "ecfinal.luogu.com.cn", "errtrack.luogu.com.cn", "fces.ccf.org.cn",
    "fecdn.luogu.com.cn", "g.alicdn.com", "o.alicdn.com", "at.alicdn.com", "aeis.alicdn.com",
    "gesp.ccf.org.cn", "help.luogu.com.cn", "hhme.ccf.org.cn", "icpc.luogu.com.cn", "ipic.luogu.com.cn",
    "jingsai.kpcb.org.cn", "kpcb.org.cn", "luogu.com.cn", "mobile.ccf.org.cn", "oa.ccf.org.cn",
    "oj.wlhcode.com", "oj.wwwos.net", "online.ccf.org.cn", "passport.ccf.org.cn", "payment.luogu.com.cn",
    "serviceprod.kpcb.org.cn", "sso.ccf.org.cn", "stream.class.luogu.com.cn", "stream-push.class.luogu.com.cn",
    "stream-rts.class.luogu.com.cn", "tf.ccf.org.cn", "ti.luogu.com.cn", "video.class.luogu.com.cn",
    "web.ccf.org.cn", "wp.wwwos.net", "ws.class.luogu.com.cn", "ws.luogu.com.cn", "api.tsinghuax.com",
    "www.ccf.org.cn", "www.kpcb.org.cn", "www.luogu.com.cn", "ygoj.wwwos.net", "comp.webtrncdn.com",
    "www.lanqiaoqingshao.cn", "api.lanqiaoqingshao.cn", "oss.lanqiaoqingshao.cn", "ynuf.aliapp.org",
    "gm.mmstat.com", "oss.stem86.com", "a.w9.ip-ddns.com", "crt.sh", "open.bigmodel.cn",
    "analytics.immersivetranslate.com", "beacons.gcp.gvt2.com", "beacons.gvt2.com", "b1.nel.goog","e2c35.gcp.gvt2.com"
)

Set-Content -Path $dnsFile -Value $null
$allSubs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 添加强制子域名
foreach ($sub in $forcedSubs) { [void]$allSubs.Add($sub) }

# 收集子域名（不包括以 * 开头的泛域名）
foreach ($d in $domains) {
    [void]$allSubs.Add($d)
    Write-Host "[*] 获取 $d 的子域名..."
    try {
        $res = Invoke-RestMethod -Uri "https://crt.sh/?q=%25.$d&output=json" -TimeoutSec 10 -ErrorAction Stop
        foreach ($entry in $res) {
            if ($entry.name_value) {
                $entry.name_value -split "`n" | ForEach-Object {
                    $sub = $_.Trim()
                    if ($sub -and -not $sub.StartsWith("*")) {
                        [void]$allSubs.Add($sub)
                    }
                }
            }
        }
    } catch {
        Write-Host "[-] 获取失败：$d"
    }
}

# 写入去重后子域名
$allSubs | Sort-Object | Set-Content -Path $dnsFile
Write-Host "[*] 共写入子域名 $($allSubs.Count) 条到 $dnsFile"
