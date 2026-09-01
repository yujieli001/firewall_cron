# get_dns.ps1 - CT + Passive DNS + DNS Brute-force Subdomain Enumerator

$ErrorActionPreference = "Continue"

# Add Go bin to PATH so subfinder/dnsx can be found
$env:PATH = "S:\Server\Go\bin;" + $env:PATH

$dnsFile = Join-Path $PSScriptRoot "dns_sub.txt"

# ====================================================================

# Target domains to enumerate

# ====================================================================

$domains = @(
"luogu.com.cn",
"acwing.com",
"iai.sh.cn",
"atcoder.jp",
#"kpcb.org.cn",
"ccf.org.cn",
#"lanqiaoqingshao.cn",
"alicdn.com",
"acmcoder.com",
"cn-hangzhou.log.aliyuncs.com"
)

# ====================================================================

# Forced subdomains list

# ====================================================================

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
"oj.wlhcode.com", "oj.wwwos.net", "online.ccf.org.cn", "bigcodeforce.cn",
"meeting.tencent.com", "publiclog.zhiyan.tencent-cloud.net", "work.medialab.qq.com", "meeting.qq.com",
"conn.wemeet.tencent.com", "report.meeting.tencent.com", "quic.conn.wemeet.qq.com",
"passport.ccf.org.cn", "payment.luogu.com.cn", "vjudge.net", "noi.cn", "cspsjtest.noi.cn",
"serviceprod.kpcb.org.cn", "sso.ccf.org.cn", "stream.class.luogu.com.cn", "stream-push.class.luogu.com.cn",
"stream-rts.class.luogu.com.cn", "tf.ccf.org.cn", "ti.luogu.com.cn", "video.class.luogu.com.cn",
"web.ccf.org.cn", "wp.wwwos.net", "ws.class.luogu.com.cn", "ws.luogu.com.cn", "api.tsinghuax.com",
"www.ccf.org.cn", "www.kpcb.org.cn", "www.luogu.com.cn", "ygoj.wwwos.net", "comp.webtrncdn.com",
"www.lanqiaoqingshao.cn", "api.lanqiaoqingshao.cn", "oss.lanqiaoqingshao.cn", "ynuf.aliapp.org",
"gm.mmstat.com", "oss.stem86.com", "a.w9.ip-ddns.com", "crt.sh", "open.bigmodel.cn",
"analytics.immersivetranslate.com", "beacons.gcp.gvt2.com", "beacons.gvt2.com", "b1.nel.goog",
"e2c35.gcp.gvt2.com",
"examacmcoder.oss-cn-beijing.aliyuncs.com",
"examacmcoder.oss-accelerate.aliyuncs.com",
"acmcoder.com",
"lanqiao.acmcoder.com",
"ws.acmcoder.com",
"tcdn.acmcoder.com",
"62885.acmcoder.com",
"all.acmcoder.com.w.kunlunsl.com",
"exam.acmcoder.com",
"exercise.acmcoder.com",
"examassets.acmcoder.com",
"cdnw2.acmcoder.com",
"c-v6.dun.163.com",
"cstaticdun-v6.126.net",
"ir-sdk-v6.dun.163.com",
"c-v6.dun.163yun.com",
"necaptcha-v6.nosdn.127.net",
"oi-wiki.org",
"oi-wiki.org.w.kunlunsl.com",
"oi-wiki.org.w.cdngslb.com",
"acwing.com",
"www.acwing.com",
"video.acwing.com",
"cdn.acwing.com",
"play.acwing.com",
"git.acwing.com",
"videocloud.cn-hangzhou.log.aliyuncs.com",
"vod.cn-shanghai.aliyuncs.com",
"oss-cn-hangzhou.aliyuncs.com"
)

# ====================================================================

# Configuration

# ====================================================================

# DNS brute-force wordlist

$wordlist = Join-Path $PSScriptRoot "subdomains.txt"

# Whether to enable DNS verification

$enableDnsVerify = $true

# Whether to enable DNS brute-force

$enableBruteforce = $true

# ====================================================================

# Initialization

# ====================================================================

Set-Content -Path $dnsFile -Value $null -Encoding UTF8

$allSubs = [System.Collections.Generic.HashSet[string]]::new(
[System.StringComparer]::OrdinalIgnoreCase
)

# ====================================================================

# Load forced subdomains

# ====================================================================

Write-Host ""
Write-Host "========================================"
Write-Host " Load forced subdomains"
Write-Host "========================================"

foreach ($sub in $forcedSubs) {
    $sub = $sub.Trim().ToLower()

    if ($sub -and -not $sub.StartsWith("*")) {
        [void]$allSubs.Add($sub)
    }
}

Write-Host "[+] Forced subdomains loaded: $($forcedSubs.Count)"

# ====================================================================

# Tool detection

# ====================================================================

$subfinderPath = Get-Command subfinder -ErrorAction SilentlyContinue
$dnsxPath      = Get-Command dnsx -ErrorAction SilentlyContinue

if ($subfinderPath) {
    Write-Host "[+] subfinder found at: $($subfinderPath.Source)"
} else {
    Write-Host "[!] subfinder not found: CT / Passive DNS will be skipped"
}

if ($dnsxPath) {
    Write-Host "[+] dnsx found at: $($dnsxPath.Source)"
} else {
    Write-Host "[!] dnsx not found: DNS verification will use Resolve-DnsName"
}

# ====================================================================

# Phase 1:

# subfinder

#
# subfinder aggregates multiple data sources:
# CT / Passive DNS / Search Engines / DNS Records etc.
#
# crt.sh is only one of many sources

# ====================================================================

Write-Host ""
Write-Host "========================================"
Write-Host " Phase 1: CT + Passive DNS"
Write-Host "========================================"

if ($subfinderPath) {
    foreach ($d in $domains) {

        Write-Host ""
        Write-Host "[*] Running enumeration: $d"

        $tmpFile = Join-Path $env:TEMP (
            "subfinder_" + `
            ($d -replace '[^a-zA-Z0-9]', '_') + ".txt"
        )

        try {

            if (Test-Path $tmpFile) {
                Remove-Item $tmpFile -Force
            }

            # -silent: only output subdomains
            # -all: use all possible data sources
            & subfinder `
                -d $d `
                -silent `
                -all `
                -o $tmpFile `
                2>$null

            if (Test-Path $tmpFile) {

                $count = 0

                foreach ($line in Get-Content $tmpFile) {

                    $sub = $line.Trim().ToLower()

                    if (
                        $sub `
                        -and `
                        -not $sub.StartsWith("*") `
                        -and `
                        $sub.EndsWith($d)
                    ) {

                        if ($allSubs.Add($sub)) {
                            $count++
                        }
                    }
                }

                Write-Host "[+] $d found $count new subdomains"
            } else {
                Write-Host "[-] ${d}: subfinder returned no results"
            }

        } catch {

            Write-Host "[-] ${d}: subfinder query failed"
        }

        if (Test-Path $tmpFile) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
} else {

    Write-Host "[!] Skipped CT + Passive DNS"
}

# ====================================================================

# Phase 2:

# DNS brute-force

# ====================================================================

Write-Host ""
Write-Host "========================================"
Write-Host " Phase 2: DNS brute-force"
Write-Host "========================================"

if ($enableBruteforce) {

    if (-not (Test-Path $wordlist)) {

        Write-Host "[!] Wordlist not found: $wordlist"
        Write-Host "[!] Skipping DNS brute-force"

    } else {

        $words = Get-Content $wordlist |
            Where-Object {
                $_.Trim() -and
                -not $_.Trim().StartsWith("#")
            }

        Write-Host "[+] Wordlist: $($words.Count) entries"

        foreach ($d in $domains) {

            Write-Host ""
            Write-Host "[*] DNS brute-force: $d"

            $found = 0

            foreach ($word in $words) {

                $word = $word.Trim()

                if (-not $word) {
                    continue
                }

                $fqdn = "$word.$d"

                try {

                    $result = Resolve-DnsName `
                        -Name $fqdn `
                        -Type A `
                        -ErrorAction Stop

                    if ($result) {

                        if ($allSubs.Add($fqdn)) {
                            $found++
                        }
                    }

                } catch {
                    # DNS lookup failed, skip
                }
            }

            Write-Host "[+] ${d}: DNS brute-force found $found"
        }
    }
} else {

    Write-Host "[!] DNS brute-force is disabled"
}

# ====================================================================

# Phase 3:

# DNS verification

#
# Some results may not work live:
# 1. Expired DNS records
# 2. Historical entries
# 3. CNAME to an expired domain
#
# Re-verify all subdomains

# ====================================================================

Write-Host ""
Write-Host "========================================"
Write-Host " Phase 3: DNS verification"
Write-Host "========================================"

if ($enableDnsVerify) {

    $verifiedSubs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $total = $allSubs.Count
    $current = 0

    foreach ($sub in $allSubs) {

        $current++

        Write-Progress `
            -Activity "DNS verification" `
            -Status "$sub" `
            -PercentComplete (($current / $total) * 100)

        try {

            $result = Resolve-DnsName `
                -Name $sub `
                -ErrorAction Stop

            if ($result) {

                [void]$verifiedSubs.Add($sub)
            }

        } catch {
            # DNS record not found or unreachable
        }
    }

    Write-Progress `
        -Activity "DNS verification" `
        -Completed

    Write-Host "[+] DNS verified before: $($allSubs.Count)"
    Write-Host "[+] DNS verified after: $($verifiedSubs.Count)"

    $allSubs = $verifiedSubs
}

# ====================================================================

# Phase 4:

# Final output

# ====================================================================

Write-Host ""
Write-Host "========================================"
Write-Host " Phase 4: Final output"
Write-Host "========================================"

$finalSubs = $allSubs |
    ForEach-Object {
        $_.Trim().ToLower()
    } |
    Where-Object {
        $_ `
            -and `
            -not $_.StartsWith("*")
    } |
    Sort-Object -Unique

# ====================================================================

# Write to file

# ====================================================================

$finalSubs | Set-Content `
    -Path $dnsFile `
    -Encoding UTF8

Write-Host ""
Write-Host "========================================"
Write-Host " Done"
Write-Host "========================================"

Write-Host "[+] Output entries: $($finalSubs.Count)"
Write-Host "[+] File: $dnsFile"
Write-Host ""