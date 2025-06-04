Set-NetFirewallProfile -All -DefaultOutboundAction Allow
Get-NetFirewallRule -Direction Outbound | Where-Object { 
    $_.DisplayName -like "Allow Outbound to Whitelist*" -or 
    $_.DisplayName -eq "Allow Local Network" 
} | Remove-NetFirewallRule
Write-Host "�ѻָ�Ĭ�ϳ�վ������Բ�ɾ���Զ������" -ForegroundColor Green
