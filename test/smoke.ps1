# Smoke test for the inbox: receive, store, retrieve.
# Usage: .\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token <INBOX_TOKEN> -LinearSecret <LINEAR_WEBHOOK_SECRET>
param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $LinearSecret
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 does not always offer TLS 1.2, which workers.dev requires.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$failures = 0

function Check($name, $condition) {
    if ($condition) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}

function Sign($secret, $body) {
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secret))
    -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)) | ForEach-Object { $_.ToString('x2') })
}

function Send($body, $signature, $delivery) {
    try {
        $r = Invoke-WebRequest "$BaseUrl/hooks/linear" -Method Post -Body $body -ContentType 'application/json' `
            -Headers @{ 'linear-signature' = $signature; 'linear-delivery' = $delivery } -UseBasicParsing
        return @{ Status = [int]$r.StatusCode; Body = ($r.Content | ConvertFrom-Json) }
    } catch {
        return @{ Status = [int]$_.Exception.Response.StatusCode; Body = $null }
    }
}

function Get-Api($path, $auth = $true) {
    $headers = @{}
    if ($auth) { $headers.Authorization = "Bearer $Token" }
    try {
        $r = Invoke-WebRequest "$BaseUrl$path" -Headers $headers -UseBasicParsing
        return @{ Status = [int]$r.StatusCode; Body = ($r.Content | ConvertFrom-Json) }
    } catch {
        return @{ Status = [int]$_.Exception.Response.StatusCode; Body = $null }
    }
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$delivery = [guid]::NewGuid().ToString()
$body = @{
    action = 'update'; type = 'Issue'; webhookTimestamp = $now
    data = @{ identifier = 'MAT-47'; title = '[claude-test] smoke'; state = @{ name = 'Todo' } }
    updatedFrom = @{ stateId = 'old' }
} | ConvertTo-Json -Compress -Depth 5
$sig = Sign $LinearSecret $body

# Receive + store
$r = Send $body $sig $delivery
Check 'valid signed webhook is accepted' ($r.Status -eq 200 -and -not $r.Body.duplicate)

$r = Send $body $sig $delivery
Check 'same delivery again is a duplicate' ($r.Status -eq 200 -and $r.Body.duplicate)

$r = Send $body ('0' * 64) ([guid]::NewGuid().ToString())
Check 'bad signature is rejected (401)' ($r.Status -eq 401)

$old = $body.Replace("$now", "$($now - 600000)")
$r = Send $old (Sign $LinearSecret $old) ([guid]::NewGuid().ToString())
Check 'old timestamp is rejected (401)' ($r.Status -eq 401)

# Retrieve
$r = Get-Api '/api/events' $false
Check 'read API without token is rejected (401)' ($r.Status -eq 401)

$r = Get-Api '/api/events?source=linear&limit=5'
$latest = $r.Body.events | Select-Object -First 1
Check 'list returns the stored event' ($r.Status -eq 200 -and $latest.delivery_id -eq $delivery)
Check 'list has no payload by default' ($null -eq $latest.payload)

$r = Get-Api "/api/events/$($latest.id)"
Check 'get by id returns the full payload' ($r.Status -eq 200 -and $r.Body.payload.data.identifier -eq 'MAT-47')

$r = Get-Api "/api/events?after=$($latest.id - 1)&payload=1"
Check 'read forward with after returns the event and next_after' ($r.Status -eq 200 -and $r.Body.events[0].id -eq $latest.id -and $r.Body.next_after -eq $latest.id)

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
