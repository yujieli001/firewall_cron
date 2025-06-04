<#
.SYNOPSIS
  限制 Windows 出站网络，仅允许访问白名单 IP 和局域网。
.DESCRIPTION
  1. 自动读取 ipv4.txt 和 ipv6.txt 文件作为白名单 IP
  2. 设置默认出站阻止策略
  3. 允许白名单 IP 出站
  4. 允许局域网通信（192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12）
.NOTES
  需要管理员权限运行！
  需要提前运行 DNS 收集脚本生成 ipv4.txt 和 ipv6.txt
#>

# ------------ 配置部分 ------------
# 从文件读取白名单 IP
$AllowedIPs = @(    
    "223.5.5.5",    # 阿里 DNS
    "223.6.6.6",    # 阿里 DNS
    "8.8.8.8",      # Google DNS
    "8.8.4.4"       # Google DNS
)

# 获取脚本所在目录
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "脚本目录: $scriptPath" -ForegroundColor Cyan

# 读取 ipv4.txt
$ipv4File = Join-Path $scriptPath "ipv4.txt"
if (Test-Path $ipv4File) {
    # 读取所有非空行，并去除空格
    $ipv4IPs = Get-Content $ipv4File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
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
    # 读取所有非空行，并去除空格
    $ipv6IPs = Get-Content $ipv6File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
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
# 要求管理员权限
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    exit
}

# 0. 确保防火墙服务正在运行
Get-Service -Name MpsSvc | Start-Service -ErrorAction SilentlyContinue

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

# ------------ 恢复选项（注释部分，需手动取消注释运行） ------------
<#
# 恢复默认设置（取消注释后运行）
Set-NetFirewallProfile -All -DefaultOutboundAction Allow
Get-NetFirewallRule -Direction Outbound | Where-Object { 
    $_.DisplayName -like "Allow Outbound to Whitelist*" -or 
    $_.DisplayName -eq "Allow Local Network" 
} | Remove-NetFirewallRule
Write-Host "已恢复默认出站允许策略并删除自定义规则。" -ForegroundColor Green
#>