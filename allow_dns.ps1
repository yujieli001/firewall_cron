# allow_dns.ps1
# ���� dns_sub.txt �е�����������ȡ IP ��ַ���޸ķ���ǽ
$dnsFile  = "dns_sub.txt"
$ipv4File = "ipv4.txt"
$ipv6File = "ipv6.txt"

Set-Content -Path $ipv4File -Value $null
Set-Content -Path $ipv6File -Value $null

# �ռ� IP ��ַ
$subs = Get-Content $dnsFile | Where-Object { $_ -and $_.Trim() -ne "" }
$i = 0
foreach ($domain in $subs) {
    $i++
    Write-Host "[$i/$($subs.Count)] ���� $domain"
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
        Write-Host "    [!] �޷�������$domain"
    }
}

# ȥ������
Get-Content $ipv4File | Sort-Object -Unique | Set-Content $ipv4File
Get-Content $ipv6File | Sort-Object -Unique | Set-Content $ipv6File
$AllowedIPs = @(
    "223.5.5.5", "223.6.6.6", "8.8.8.8", "8.8.4.4"
) + (Get-Content $ipv4File) + (Get-Content $ipv6File)

# ��Ҫ����ԱȨ��
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "���Թ���Ա������д˽ű���" -ForegroundColor Red
    exit
}

# ��ȡ�ű�����Ŀ¼
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "�ű�Ŀ¼: $scriptPath" -ForegroundColor Cyan

# ��ȡ ipv4.txt
$ipv4File = Join-Path $scriptPath "ipv4.txt"
if (Test-Path $ipv4File) {
    $ipv4IPs = @("142.171.157.43")
    # ��ȡ���зǿ��У���ȥ���ո�
    $ipv4IPs += Get-Content $ipv4File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                ForEach-Object { $_.Trim() } | 
                Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
    
    $ipv4Count = ($ipv4IPs | Measure-Object).Count
    Write-Host "�� $ipv4File ��ȡ�� $ipv4Count �� IPv4 ��ַ" -ForegroundColor Cyan
    
    if ($ipv4Count -gt 0) {
        $AllowedIPs += $ipv4IPs
    } else {
        Write-Host "����: $ipv4File ��û����Ч�� IPv4 ��ַ" -ForegroundColor Yellow
    }
}
else {
    Write-Host "����: $ipv4File �ļ������ڣ������� IPv4 ������" -ForegroundColor Yellow
}

# ��ȡ ipv6.txt
$ipv6File = Join-Path $scriptPath "ipv6.txt"
if (Test-Path $ipv6File) {
    $ipv6IPs = @("2607:f130:0:159::d77f:d2d1")
    # ��ȡ���зǿ��У���ȥ���ո�
    $ipv6IPs += Get-Content $ipv6File | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                ForEach-Object { $_.Trim() } | 
                Where-Object { $_ -match ':' }  # ��IPv6���
    
    $ipv6Count = ($ipv6IPs | Measure-Object).Count
    Write-Host "�� $ipv6File ��ȡ�� $ipv6Count �� IPv6 ��ַ" -ForegroundColor Cyan
    
    if ($ipv6Count -gt 0) {
        $AllowedIPs += $ipv6IPs
    } else {
        Write-Host "����: $ipv6File ��û����Ч�� IPv6 ��ַ" -ForegroundColor Yellow
    }
}
else {
    Write-Host "����: $ipv6File �ļ������ڣ������� IPv6 ������" -ForegroundColor Yellow
}

# ------------ ִ�в��� ------------
# 0. ȷ������ǽ������������,����ɹ���
Get-Service -Name MpsSvc | Start-Service -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName "Allow Local Network" | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName "Allow Outbound to Whitelist Part *" | Remove-NetFirewallRule

# 1. ���������ͨ�ţ����������жϣ�
Write-Host "���������ͨ��..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Allow Local Network" -Direction Outbound -Action Allow `
    -RemoteAddress @("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12") `
    -Profile Any -Enabled True -ErrorAction SilentlyContinue

# 2. ��������� IP ��վ���ֿ鴦����ⳬ�ޣ�
$chunkSize = 500  # ÿ���������500��IP
$ipCount = $AllowedIPs.Count
$chunks = [math]::Ceiling($ipCount / $chunkSize)

Write-Host "��Ӱ��������� ($ipCount ��IP, �� $chunks ������)..." -ForegroundColor Cyan

for ($i = 0; $i -lt $chunks; $i++) {
    $start = $i * $chunkSize
    $end = [math]::Min(($start + $chunkSize - 1), ($ipCount - 1))
    $chunkIPs = $AllowedIPs[$start..$end] | Where-Object { $_ }
    
    if ($chunkIPs) {
        $ruleName = "Allow Outbound to Whitelist Part $($i+1)"
        Write-Host "�������� $ruleName (���� $($chunkIPs.Count) �� IP)"
        New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Allow `
            -RemoteAddress $chunkIPs -Profile Any -Enabled True -ErrorAction SilentlyContinue
    }
}

# 3. ����Ĭ�ϳ�վ��ֹ����
Write-Host "����Ĭ�ϳ�վ��ֹ����..." -ForegroundColor Cyan
Set-NetFirewallProfile -All -DefaultOutboundAction Block

# ���
Write-Host "������ɣ���������ʰ����� IP �;�������" -ForegroundColor Green
Write-Host "������ IP ����: $($AllowedIPs.Count)" -ForegroundColor Yellow
Write-Host "��������: ping 192.168.1.254, ping 8.8.8.8��Ӧ����ͨ��, ping 1.1.1.1��Ӧ����ֹ��" -ForegroundColor Yellow
