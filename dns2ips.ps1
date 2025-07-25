# ================================================
# �ļ�·��˵�����ɸ���ʵ������޸ģ���
#   �������б�:    ./dns_sub.txt
#   IPv4 ���:     ./ipv4.txt
#   IPv6 ���:     ./ipv6.txt
# ================================================

# 1. ��������������
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

# 2. ��ʼ�����Ŀ¼ + ����ϴν��

# ��գ��򴴽���dns_sub.txt��ipv4.txt��ipv6.txt
$dnsFile   = "dns_sub.txt"
$ipv4File  = "ipv4.txt"
$ipv6File  = "ipv6.txt"

# �ÿ����ݸ��ǣ������������Զ��������ļ�
Set-Content -Path $dnsFile  -Value $null
Set-Content -Path $ipv4File -Value $null
Set-Content -Path $ipv6File -Value $null

# 3. ǿ����ӵ����������� shell �ű�����һ�£�
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
# ��ǿ��������д�� dns_sub.txt
$forcedSubs | ForEach-Object { Add-Content -Path $dnsFile -Value $_ }

Write-Host "[*] ��д��ǿ�������������� $($forcedSubs.Count) ����"

# 4. �� crt.sh ��ȡ���ռ����������������� HashSet ��ȥ��
$allSubdomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 4.1 �Ȱ�ǿ������������ HashSet
foreach ($sub in $forcedSubs) {
    [void]$allSubdomains.Add($sub)
}

# 4.2 �������������� crt.sh ��ȡ JSON ����ȡ������
foreach ($base in $DOMAINS) {
    Write-Host "[*] ��ȡ $base ���������б�..."
    $url = "https://crt.sh/?q=%25.$base&output=json"

    try {
        # --max-time �ȼ۲�����-TimeoutSec
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop

        # response ��һ���������飬�������� name_value
        foreach ($entry in $response) {
            if ($null -ne $entry.name_value) {
                # name_value ����ܰ������У��Ի��зָ�
                $subs = $entry.name_value -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
                foreach ($sub in $subs) {
                    [void]$allSubdomains.Add($sub)
                }
            }
        }
    }
    catch {
        Write-Host "[-] ��ȡ $base ������ʧ�ܣ����������� $_"
    }
}

# 4.3 ���������������Ҳ�ӵ�������� shell �ű��߼�����һ�£�
foreach ($d in $DOMAINS) {
    [void]$allSubdomains.Add($d)
}

# 5. ��ȥ�غ��������ȫ��д�� dns_sub.txt��������
#    ����գ�Ȼ��д������������������
Set-Content -Path $dnsFile -Value $null
$allSubdomains  `
    | Sort-Object `
    | ForEach-Object { Add-Content -Path $dnsFile -Value $_ }

$total = $allSubdomains.Count
Write-Host "[*] ����ȡ�� $total ������������д�� $dnsFile��"

# 6. �������ÿ�������������� IPv4/IPv6 д�벻ͬ�ļ�
$i = 0
foreach ($domain in $allSubdomains) {
    $i++
    if (![string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "    [$i/$total] ���ڽ��� $domain ..."
        try {
            # GetHostAddresses �᷵�� IPv4 �� IPv6 ��ַ����
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
                            # ���������ݲ�����
                        }
                    }
                }
                catch {
                    # �Ƿ� IP �ַ���������
                }
            }
        }
        catch {
            Write-Host "    [!] ����ʧ�ܣ� $domain"
        }
    }
}

# 7. �� ipv4.txt��ipv6.txt �ٴ�ȥ�� + ����
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

# 8. ������ս������
$ipv4Count = 0
$ipv6Count = 0
if (Test-Path $ipv4File) {
    $ipv4Count = (Get-Content $ipv4File | Measure-Object).Count
}
if (Test-Path $ipv6File) {
    $ipv6Count = (Get-Content $ipv6File | Measure-Object).Count
}

Write-Host "[*] ������ɣ�"
Write-Host "[*] IPv4 ��ַ����: $ipv4Count"
Write-Host "[*] IPv6 ��ַ����: $ipv6Count"
