$DOMAINS = @(
    "luogu.com.cn",
    "kpcb.org.cn",
    "wlhcode.com",
    "oj.wwwos.net",
    "ccf.org.cn",
    "noi.cn",
    "nbyg.net"
)

# 清空上次运行结果
Set-Content -Path "dns_sub.txt" -Value $null
Set-Content -Path "ipv4.txt" -Value $null
Set-Content -Path "ipv6.txt" -Value $null

Write-Host "[*] 开始从 crt.sh 获取多个域名的子域名并解析 IP ..."

# 用于存储所有子域名的集合
$allSubdomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($BASE_DOMAIN in $DOMAINS) {
    Write-Host "[*] 获取 ${BASE_DOMAIN} 的子域名列表..."
    $url = "https://crt.sh/?q=%25.${BASE_DOMAIN}&output=json"
    
    try {
        $response = Invoke-RestMethod -Uri $url -ErrorAction Stop
        
        # 收集并处理所有子域名
        $response | ForEach-Object { 
            $subs = $_.name_value -split "`n" | Where-Object { 
                -not [string]::IsNullOrWhiteSpace($_) 
            } | ForEach-Object { $_.Trim() }
            
            foreach ($sub in $subs) {
                if (-not [string]::IsNullOrWhiteSpace($sub)) {
                    # 添加到全局集合
                    [void]$allSubdomains.Add($sub)
                }
            }
        }
    }
    catch {
        Write-Host "[!] 获取 ${BASE_DOMAIN} 子域名失败: $_"
    }
}

# 添加主域名
foreach ($domain in $DOMAINS) {
    [void]$allSubdomains.Add($domain)
}

# 写入dns_sub.txt - 确保没有空行
$allSubdomains | Sort-Object | Set-Content -Path "dns_sub.txt"

$total = $allSubdomains.Count
Write-Host "[*] 共获取到 $total 个子域名，开始解析 IP ..."

$i = 0
foreach ($domain in $allSubdomains) {
    $i++
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "    [$i/$total] $domain 解析中..."
        
        try {
            # 解析所有IP地址
            $ips = [System.Net.Dns]::GetHostAddresses($domain) | 
                   Select-Object -ExpandProperty IPAddressToString -ErrorAction SilentlyContinue
            
            foreach ($ip in $ips) {
                # 使用.NET方法精确区分IPv4/IPv6
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
                    # 非标准IP格式，跳过
                }
            }
        }
        catch {
            Write-Host "    [!] 解析失败: $domain"
        }
    }
}

# 去重并排序IP文件
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

Write-Host "[*] 操作完成!"
Write-Host "[*] IPv4 地址数量: $(if (Test-Path "ipv4.txt") { (Get-Content "ipv4.txt" | Measure-Object).Count } else {0})"
Write-Host "[*] IPv6 地址数量: $(if (Test-Path "ipv6.txt") { (Get-Content "ipv6.txt" | Measure-Object).Count } else {0})"