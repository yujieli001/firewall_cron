# get_dns.ps1 - ���ռ��� * ��ͷ����������д�� dns_sub.txt
$dnsFile = "dns_sub.txt"
$domains = @(
    "luogu.com.cn", "iai.sh.cn", "atcoder.jp", "kpcb.org.cn", "ccf.org.cn",
    "oss-cn-hangzhou.aliyuncs.com", "lanqiaoqingshao.cn", "alicdn.com", "acmcoder.com"
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
    "analytics.immersivetranslate.com", "beacons.gcp.gvt2.com", "beacons.gvt2.com", "b1.nel.goog","e2c35.gcp.gvt2.com",
    "examacmcoder.oss-cn-beijing.aliyuncs.com","examacmcoder.oss-accelerate.aliyuncs.com","acmcoder.com",
    "lanqiao.acmcoder.com","ws.acmcoder.com","tcdn.acmcoder.com","62885.acmcoder.com","all.acmcoder.com.w.kunlunsl.com",
    "alb-cz0efer2d8r287ath9.cn-beijing.alb.aliyuncs.com","exam.acmcoder.com","exercise.acmcoder.com",
    "pel9t1l49r4hy553.aliyunddos1013.com","labfiles.acmcoder.com.w.cdngslb.com","088bxw1q70s5dsjk.aliyunddos1013.com",
    "51b9047024eu1o81.aliyunddos1013.com","7q2c176p6t5vh87n.aliyunddos1013.com",
    "examassets.acmcoder.com","cdnw2.acmcoder.com"
)

Set-Content -Path $dnsFile -Value $null
$allSubs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# ���ǿ��������
foreach ($sub in $forcedSubs) { [void]$allSubs.Add($sub) }

# �ռ����������������� * ��ͷ�ķ�������
foreach ($d in $domains) {
    [void]$allSubs.Add($d)
    Write-Host "[*] ��ȡ $d ��������..."
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
        Write-Host "[-] ��ȡʧ�ܣ�$d"
    }
}

# д��ȥ�غ�������
$allSubs | Sort-Object | Set-Content -Path $dnsFile
Write-Host "[*] ��д�������� $($allSubs.Count) ���� $dnsFile"
