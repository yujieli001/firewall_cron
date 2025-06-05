$DOMAINS = @(
    "luogu.com.cn",
    "kpcb.org.cn",
    "wlhcode.com",
    "oj.wwwos.net",
    "ccf.org.cn",
    "noi.cn",
    "nbyg.net"
)

# ����ϴ����н��
Set-Content -Path "dns_sub.txt" -Value $null
Set-Content -Path "ipv4.txt" -Value $null
Set-Content -Path "ipv6.txt" -Value $null

Write-Host "[*] ��ʼ�� crt.sh ��ȡ��������������������� IP ..."

# ���ڴ洢�����������ļ���
$allSubdomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($BASE_DOMAIN in $DOMAINS) {
    Write-Host "[*] ��ȡ ${BASE_DOMAIN} ���������б�..."
    $url = "https://crt.sh/?q=%25.${BASE_DOMAIN}&output=json"
    
    try {
        $response = Invoke-RestMethod -Uri $url -ErrorAction Stop
        
        # �ռ�����������������
        $response | ForEach-Object { 
            $subs = $_.name_value -split "`n" | Where-Object { 
                -not [string]::IsNullOrWhiteSpace($_) 
            } | ForEach-Object { $_.Trim() }
            
            foreach ($sub in $subs) {
                if (-not [string]::IsNullOrWhiteSpace($sub)) {
                    # ��ӵ�ȫ�ּ���
                    [void]$allSubdomains.Add($sub)
                }
            }
        }
    }
    catch {
        Write-Host "[!] ��ȡ ${BASE_DOMAIN} ������ʧ��: $_"
    }
}

# ���������
foreach ($domain in $DOMAINS) {
    [void]$allSubdomains.Add($domain)
}

# д��dns_sub.txt - ȷ��û�п���
$allSubdomains | Sort-Object | Set-Content -Path "dns_sub.txt"

$total = $allSubdomains.Count
Write-Host "[*] ����ȡ�� $total ������������ʼ���� IP ..."

$i = 0
foreach ($domain in $allSubdomains) {
    $i++
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "    [$i/$total] $domain ������..."
        
        try {
            # ��������IP��ַ
            $ips = [System.Net.Dns]::GetHostAddresses($domain) | 
                   Select-Object -ExpandProperty IPAddressToString -ErrorAction SilentlyContinue
            
            foreach ($ip in $ips) {
                # ʹ��.NET������ȷ����IPv4/IPv6
                try {
                    $addr = [System.Net.IPAddress]::Parse($ip)
                    if ($addr.AddressFamily -eq 'InterNetwork') {
                        Add-Content -Path "ipv4.txt" -Value $ip
                    }
                    elseif ($addr.AddressFamily -eq 'InterNetworkV6') {
                        Add-Content -Path "ipv6.txt" -Value $ip
                    }
                }
                catch {
                    # �Ǳ�׼IP��ʽ������
                }
            }
        }
        catch {
            Write-Host "    [!] ����ʧ��: $domain"
        }
    }
}

# ȥ�ز�����IP�ļ�
if (Test-Path "ipv4.txt") {
    Get-Content -Path "ipv4.txt" | Sort-Object -Unique | Set-Content -Path "ipv4.txt"
}
else {
    Set-Content -Path "ipv4.txt" -Value $null
}

if (Test-Path "ipv6.txt") {
    Get-Content -Path "ipv6.txt" | Sort-Object -Unique | Set-Content -Path "ipv6.txt"
}
else {
    Set-Content -Path "ipv6.txt" -Value $null
}

Write-Host "[*] �������!"
Write-Host "[*] IPv4 ��ַ����: $(if (Test-Path "ipv4.txt") { (Get-Content "ipv4.txt" | Measure-Object).Count } else {0})"
Write-Host "[*] IPv6 ��ַ����: $(if (Test-Path "ipv6.txt") { (Get-Content "ipv6.txt" | Measure-Object).Count } else {0})"