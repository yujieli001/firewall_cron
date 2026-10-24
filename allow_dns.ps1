# allow_dns.ps1
# Resolve IPs from dns.txt and configure firewall
#
# Multi-run IP accumulation, mirroring ubuntu/firewall.sh: every IP ever
# resolved is kept in state files under $stateDir and re-allowed on later
# runs, i.e. the loaded whitelist = history UNION this run. CDN DNS
# round-robin answers each query with only a subset of the address pool,
# so a one-shot snapshot misses the rest and shows up as "site worked a
# second ago, dead after refresh"; accumulating across runs covers the
# pool gradually. Trade-off (same as the ubuntu side): the allow surface
# grows monotonically. To shrink it again, delete whitelist4.txt and
# whitelist6.txt in the state dir and run once.

$scriptDir = $PSScriptRoot
$dnsFile  = Join-Path $scriptDir "dns.txt"
$ipv4File = Join-Path $scriptDir "ipv4.txt"
$ipv6File = Join-Path $scriptDir "ipv6.txt"

# State dir decoupled from the script dir (the /var/lib/firewall_cron
# equivalent: survives reboots and script-dir moves). Override with the
# STATE_DIR environment variable, handy for testing.
if ($env:STATE_DIR) { $stateDir = $env:STATE_DIR }
else { $stateDir = Join-Path $env:ProgramData "firewall_cron" }
$state4File = Join-Path $stateDir "whitelist4.txt"
$state6File = Join-Path $stateDir "whitelist6.txt"

# Address format checks, same spirit as the awk regexes in firewall.sh:
# a hand-edited or corrupted state file must not inject junk into rules.
$RE_V4 = '^\d{1,3}(\.\d{1,3}){3}$'
$RE_V6 = '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$'

# Fixed allows independent of dns.txt. Unlike the iptables variant (which
# only drops tcp/udp 80+443) this script arms a default-BLOCK policy, so
# plain DNS on port 53 has to be allowed explicitly here. The last two
# addresses are static hosts carried over from the old version of this
# script (purpose not documented there either - kept as-is).
$ExtraIPs = @(
    "223.5.5.5", "223.6.6.6", "8.8.8.8", "8.8.4.4",
    "142.171.157.43",
    "2607:f130:0:159::d77f:d2d1"
)

function Load-IPSet {
    param([string]$Path, [string]$Pattern)
    # Line-by-line validation; lower-cased keys keep one IPv6 stored once
    # regardless of how it was spelled.
    $set = @{}
    if (Test-Path $Path) {
        foreach ($line in @(Get-Content $Path)) {
            $addr = "$line".Trim().ToLowerInvariant()
            if ($addr -and $addr -match $Pattern) { $set[$addr] = $true }
        }
    }
    return $set
}

function Save-IPSet {
    param([string]$Path, $Set)
    # An empty set must never wipe accumulated history: one failed
    # resolution run should not undo every earlier run's work.
    if ($Set.Count -eq 0) { return }
    try {
        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        # Write a temp file then rename: a crash mid-write cannot destroy
        # the previous history.
        $tmp = "$Path.tmp_$PID"
        $Set.Keys | Sort-Object | Set-Content -Path $tmp -Encoding ascii
        Move-Item -Path $tmp -Destination $Path -Force
    } catch {
        # History bookkeeping failing must not block applying the firewall
        # rules - warn loudly instead.
        Write-Host "WARNING: cannot save state file ${Path}: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "         (rules are still applied; this run's IPs are not recorded for later runs)" -ForegroundColor Yellow
    }
}

# ---------------- Resolve this run's IPs from dns.txt -----------------
if (-not (Test-Path $dnsFile)) {
    Write-Host "ERROR: $dnsFile not found" -ForegroundColor Red
    exit 1
}

# Read domain list (skip blank/#/* lines, same cleaning as ubuntu side)
$subs = @(Get-Content $dnsFile | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[#*]' })
$total = $subs.Count
if ($total -eq 0) {
    Write-Host "ERROR: $dnsFile contains no entries" -ForegroundColor Red
    exit 1
}

# Resolve domains (compatible with PowerShell 5.1).
# Hashtables act as sets: dedup on insert instead of O(n^2) array +=.
$cur4 = @{}
$cur6 = @{}
$i = 0
foreach ($domain in $subs) {
    $i++
    $domain = $domain.Trim()
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($domain)
        foreach ($addr in $addresses) {
            if ($addr.AddressFamily -eq "InterNetwork") {
                $cur4[$addr.ToString()] = $true
            }
            elseif ($addr.AddressFamily -eq "InterNetworkV6") {
                $cur6[$addr.ToString().ToLowerInvariant()] = $true
            }
        }
        Write-Host "[$i/$total] $domain -> OK"
    } catch {
        Write-Host "[$i/$total] $domain -> FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$cur4List = @($cur4.Keys | Sort-Object)
$cur6List = @($cur6.Keys | Sort-Object)
Write-Host "Resolved $total domains -> $($cur4List.Count) IPv4, $($cur6List.Count) IPv6" -ForegroundColor Green

# Snapshot of this run for inspection. Written only after resolving and
# never with an empty result: the old script truncated both files on
# entry, so one dead-DNS run destroyed the previous snapshot for nothing.
if ($cur4List.Count -gt 0) { $cur4List | Set-Content $ipv4File -Encoding ascii }
if ($cur6List.Count -gt 0) { $cur6List | Set-Content $ipv6File -Encoding ascii }

# ---------------- Accumulate: history UNION this run ------------------
$hist4 = Load-IPSet $state4File $RE_V4
$hist6 = Load-IPSet $state6File $RE_V6
$hist4Count = $hist4.Count
$hist6Count = $hist6.Count
foreach ($ip in $cur4.Keys) { $hist4[$ip] = $true }
foreach ($ip in $cur6.Keys) { $hist6[$ip] = $true }
Save-IPSet $state4File $hist4
Save-IPSet $state6File $hist6
$acc4 = @($hist4.Keys)
$acc6 = @($hist6.Keys)

# Nothing resolved this run: fall back to the accumulated set, far safer
# than arming a block-everything policy with a near-empty whitelist.
if ($cur4List.Count -eq 0 -and $acc4.Count -gt 0) {
    Write-Host "[!] Nothing resolved this run, falling back to $($acc4.Count) accumulated IPv4" -ForegroundColor Yellow
}
# Both current and history empty: refuse to touch the firewall at all
# (the old script would have set default-BLOCK with almost no allows).
if ($acc4.Count -eq 0) {
    Write-Host "ERROR: no IPv4 in this run or in history; firewall left untouched. Fix DNS, then re-run." -ForegroundColor Red
    exit 1
}
Write-Host ("IPv4: history {0} + new {1} = {2}" -f $hist4Count, ($acc4.Count - $hist4Count), $acc4.Count)
Write-Host ("IPv6: history {0} + new {1} = {2}" -f $hist6Count, ($acc6.Count - $hist6Count), $acc6.Count)

# Require admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator" -ForegroundColor Red
    exit 1
}

# Build allowed IPs: fixed extra allows + accumulated whitelist, deduped.
# (The old script appended every resolved IP twice - once from memory,
# once via re-reading the ipv4.txt it had just written - which doubled
# rule payload for no gain.)
$AllowedIPs = @($ExtraIPs + $acc4 + $acc6 | Where-Object { $_ } | Sort-Object -Unique)

# ------------ Firewall rules ------------
Get-Service -Name MpsSvc | Start-Service -ErrorAction SilentlyContinue

# Remove old rules (ignore errors if not found)
# NOTE: these DisplayNames are the contract with clear_ips.ps1 - keep in sync
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
