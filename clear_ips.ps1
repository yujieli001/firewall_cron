Set-NetFirewallProfile -All -DefaultOutboundAction Allow
Get-NetFirewallRule -Direction Outbound | Where-Object { 
    $_.DisplayName -like "Allow Outbound to Whitelist*" -or 
    $_.DisplayName -eq "Allow Local Network" 
} | Remove-NetFirewallRule
Write-Host "已恢复默认出站允许策略并删除自定义规则。" -ForegroundColor Green
