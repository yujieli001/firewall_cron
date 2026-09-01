# allow_dns.ps1
# Resolve IPs from dns_sub.txt and configure firewall

$scriptDir = $PSScriptRoot
$dnsFile  = Join-Path $scriptDir "dns_sub.txt"
$ipv4File = Join-Path $scriptDir "ipv4.txt"
$ipv6File = Join-Path $scriptDir "ipv6.txt"

# Clear old IP files
Set-Content -Path $ipv4File -Value $null
Set-Content -Path $ipv6File -Value $null

# Read domain list
$subs = Get-Content $dnsFile | Where-Object { $_ -and $_.Trim() -ne "" }
$total = $subs.Count

# Resolve domains (compatible with PowerShell 5.1)
$ipv4Array = @()
$ipv6Array = @()
$i = 0
foreach ($domain in $subs) {
    $i++
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($domain)
        foreach ($addr in $addresses) {
            if ($addr.AddressFamily -eq "InterNetwork") {
                $ipv4Array += $addr.ToString()
            }
            elseif ($addr.AddressFamily -eq "InterNetworkV6") {
                $ipv6Array += $addr.ToString()
            }
        }
        Write-Host "[$i/$total] $domain -> OK"
    } catch {
        Write-Host "[$i/$total] $domain -> FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Deduplicate
$ipv4Array = ($ipv4Array | Sort-Object -Unique)
$ipv6Array = ($ipv6Array | Sort-Object -Unique)
$ipv4Array | Set-Content $ipv4File
$ipv6Array | Set-Content $ipv6File

Write-Host "Resolved $total domains -> $($ipv4Array.Count) IPv4, $($ipv6Array.Count) IPv6" -ForegroundColor Green

# Require admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator" -ForegroundColor Red
    exit 1
}

# Build allowed IPs list
$AllowedIPs = @(
    "223.5.5.5", "223.6.6.6", "8.8.8.8", "8.8.4.4"
) + $ipv4Array + $ipv6Array

# Read ipv4.txt and append
if (Test-Path $ipv4File) {
    $ipv4IPs = @("142.171.157.43")
    $ipv4IPs += Get-Content $ipv4File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }

    $ipv4Count = ($ipv4IPs | Measure-Object).Count
    Write-Host "Read $ipv4Count IPv4 from $ipv4File" -ForegroundColor Cyan
    if ($ipv4Count -gt 0) {
        $AllowedIPs += $ipv4IPs
    }
}

# Read ipv6.txt and append
if (Test-Path $ipv6File) {
    $ipv6IPs = @("2607:f130:0:159::d77f:d2d1")
    $ipv6IPs += Get-Content $ipv6File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match ':' }

    $ipv6Count = ($ipv6IPs | Measure-Object).Count
    Write-Host "Read $ipv6Count IPv6 from $ipv6File" -ForegroundColor Cyan
    if ($ipv6Count -gt 0) {
        $AllowedIPs += $ipv6IPs
    }
}

# ------------ Firewall rules ------------
Get-Service -Name MpsSvc | Start-Service -ErrorAction SilentlyContinue

# Remove old rules (ignore errors if not found)
Remove-NetFirewallRule -DisplayName "Allow Local Network" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Allow Outbound to Whitelist Part *" -ErrorAction SilentlyContinue

# Allow LAN outbound
Write-Host "Allowing LAN outbound..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Allow Local Network" -Direction Outbound -Action Allow `
    -RemoteAddress @("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12") `
    -Profile Any -ErrorAction SilentlyContinue

# Allow whitelist outbound (chunked)
$chunkSize = 500
$ipCount = $AllowedIPs.Count
$chunks = [math]::Ceiling($ipCount / $chunkSize)
Write-Host "Creating rules ($ipCount IPs, $chunks chunks)..." -ForegroundColor Cyan

for ($i = 0; $i -lt $chunks; $i++) {
    $start = $i * $chunkSize
    $end = [math]::Min(($start + $chunkSize - 1), ($ipCount - 1))
    $chunkIPs = $AllowedIPs[$start..$end] | Where-Object { $_ }

    if ($chunkIPs) {
        $ruleName = "Allow Outbound to Whitelist Part " + ($i + 1)
        Write-Host "Rule: $ruleName ($($chunkIPs.Count) IPs)"
        New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Allow `
            -RemoteAddress $chunkIPs -Profile Any -ErrorAction SilentlyContinue
    }
}

# Default outbound block
Write-Host "Setting default outbound block..." -ForegroundColor Cyan
Set-NetFirewallProfile -All -DefaultOutboundAction Block

Write-Host "Done! Only whitelisted IPs and LAN allowed." -ForegroundColor Green
Write-Host "Total allowed IPs: $($AllowedIPs.Count)" -ForegroundColor Yellow
Write-Host "Test: ping 192.168.1.254 / 8.8.8.8 should work, ping 1.1.1.1 should fail" -ForegroundColor Yellow