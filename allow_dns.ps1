# allow_dns.ps1
# 解析 dns_sub.txt 中的子域名，获取 IP 地址并修改防火墙
$dnsFile  = "dns_sub.txt"
$ipv4File = "ipv4.txt"
$ipv6File = "ipv6.txt"

Set-Content -Path $ipv4File -Value $null
Set-Content -Path $ipv6File -Value $null

# 收集 IP 地址
$subs = Get-Content $dnsFile | Where-Object { $_ -and $_.Trim() -ne "" }
$i = 0
foreach ($domain in $subs) {
    $i++
    Write-Host "[$i/$($subs.Count)] 解析 $domain"
    try {
        [System.Net.Dns]::GetHostAddresses($domain) | ForEach-Object {
            if ($_.AddressFamily -eq "InterNetwork") {
                Add-Content -Path $ipv4File -Value $_.ToString()
            }
            elseif ($_.AddressFamily -eq "InterNetworkV6") {
                Add-Content -Path $ipv6File -Value $_.ToString()
            }
        }
    } catch {
        Write-Host "    [!] 无法解析：$domain"
    }
}

# 去重排序
Get-Content $ipv4File | Sort-Object -Unique | Set-Content $ipv4File
Get-Content $ipv6File | Sort-Object -Unique | Set-Content $ipv6File
$AllowedIPs = @(
    "223.5.5.5", "223.6.6.6", "8.8.8.8", "8.8.4.4"
) + (Get-Content $ipv4File) + (Get-Content $ipv6File)

# 需要管理员权限
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    exit
}

# 获取脚本所在目录
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "脚本目录: $scriptPath" -ForegroundColor Cyan

# 读取 ipv4.txt
$ipv4File = Join-Path $scriptPath "ipv4.txt"
if (Test-Path $ipv4File) {
    $ipv4IPs = @("142.171.157.43")
    # 读取所有非空行，并去除空格
    $ipv4IPs += Get-Content $ipv4File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                ForEach-Object { $_.Trim() } | 
                Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
    
    $ipv4Count = ($ipv4IPs | Measure-Object).Count
    Write-Host "从 $ipv4File 读取到 $ipv4Count 个 IPv4 地址" -ForegroundColor Cyan
    
    if ($ipv4Count -gt 0) {
        $AllowedIPs += $ipv4IPs
    } else {
        Write-Host "警告: $ipv4File 中没有有效的 IPv4 地址" -ForegroundColor Yellow
    }
}
else {
    Write-Host "警告: $ipv4File 文件不存在，将跳过 IPv4 白名单" -ForegroundColor Yellow
}

# 读取 ipv6.txt
$ipv6File = Join-Path $scriptPath "ipv6.txt"
if (Test-Path $ipv6File) {
    $ipv6IPs = @("2607:f130:0:159::d77f:d2d1")
    # 读取所有非空行，并去除空格
    $ipv6IPs += Get-Content $ipv6File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                ForEach-Object { $_.Trim() } | 
                Where-Object { $_ -match ':' }  # 简化IPv6检测
    
    $ipv6Count = ($ipv6IPs | Measure-Object).Count
    Write-Host "从 $ipv6File 读取到 $ipv6Count 个 IPv6 地址" -ForegroundColor Cyan
    
    if ($ipv6Count -gt 0) {
        $AllowedIPs += $ipv6IPs
    } else {
        Write-Host "警告: $ipv6File 中没有有效的 IPv6 地址" -ForegroundColor Yellow
    }
}
else {
    Write-Host "警告: $ipv6File 文件不存在，将跳过 IPv6 白名单" -ForegroundColor Yellow
}

# ------------ 执行部分 ------------
# 0. 确保防火墙服务正在运行,清除旧规则
Get-Service -Name MpsSvc | Start-Service -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName "Allow Local Network" | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName "Allow Outbound to Whitelist Part *" | Remove-NetFirewallRule

# 1. 允许局域网通信（避免内网中断）
Write-Host "允许局域网通信..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Allow Local Network" -Direction Outbound -Action Allow `
    -RemoteAddress @("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12") `
    -Profile Any -Enabled True -ErrorAction SilentlyContinue

# 2. 允许白名单 IP 出站（分块处理避免超限）
$chunkSize = 500  # 每个规则最多500个IP
$ipCount = $AllowedIPs.Count
$chunks = [math]::Ceiling($ipCount / $chunkSize)

Write-Host "添加白名单规则 ($ipCount 个IP, 分 $chunks 个规则)..." -ForegroundColor Cyan

for ($i = 0; $i -lt $chunks; $i++) {
    $start = $i * $chunkSize
    $end = [math]::Min(($start + $chunkSize - 1), ($ipCount - 1))
    $chunkIPs = $AllowedIPs[$start..$end] | Where-Object { $_ }
    
    if ($chunkIPs) {
        $ruleName = "Allow Outbound to Whitelist Part $($i+1)"
        Write-Host "创建规则 $ruleName (包含 $($chunkIPs.Count) 个 IP)"
        New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Allow `
            -RemoteAddress $chunkIPs -Profile Any -Enabled True -ErrorAction SilentlyContinue
    }
}

# 3. 设置默认出站阻止策略
Write-Host "配置默认出站阻止策略..." -ForegroundColor Cyan
Set-NetFirewallProfile -All -DefaultOutboundAction Block

# 完成
Write-Host "配置完成！仅允许访问白名单 IP 和局域网。" -ForegroundColor Green
Write-Host "白名单 IP 数量: $($AllowedIPs.Count)" -ForegroundColor Yellow
Write-Host "测试命令: ping 192.168.1.254, ping 8.8.8.8（应能连通）, ping 1.1.1.1（应被阻止）" -ForegroundColor Yellow
