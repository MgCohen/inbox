# Smoke test for the inbox: receive, store, retrieve.
# Usage: .\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token <INBOX_TOKEN> -LinearSecret <LINEAR_WEBHOOK_SECRET> [-NotionSecret <NOTION_WEBHOOK_SECRET>]
# Without -NotionSecret, the Worker must have no NOTION_WEBHOOK_SECRET, and the test checks the Notion handshake.
# With -NotionSecret, the test checks signed Notion events.
param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $LinearSecret,
    [string] $NotionSecret
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

function Post-Api($path, $body) {
    try {
        $r = Invoke-WebRequest "$BaseUrl$path" -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress -Depth 5) -UseBasicParsing
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

# Consume
$id = $latest.id
$window = "after=$($id - 1)"   # only the smoke event, also on a database with real events
$run = Get-Random -Maximum 1000000
$a = "smoke-a-$run"; $b = "smoke-b-$run"; $c = "smoke-c-$run"

$r = Get-Api '/api/events?pending=1'
Check 'pending without consumer is rejected (400)' ($r.Status -eq 400)

$r = Get-Api '/api/events?consumer=Bad%20Name'
Check 'invalid consumer name is rejected (400)' ($r.Status -eq 400)

$r = Get-Api "/api/events?consumer=$a&pending=1&$window"
Check 'new event is pending for a consumer' ($r.Status -eq 200 -and ($r.Body.events.id -contains $id) -and $null -eq $r.Body.events[0].consumed_at)

$r = Get-Api "/api/events?consumer=$a&pending=1&consume=1&$window"
Check 'consume=1 returns the event and marks it' ($r.Status -eq 200 -and ($r.Body.events.id -contains $id) -and $r.Body.events[0].consumed_at)

$r = Get-Api "/api/events?consumer=$a&pending=1&$window"
Check 'consumed event is no longer pending for that consumer' ($r.Status -eq 200 -and -not ($r.Body.events.id -contains $id))

$r = Get-Api "/api/events?consumer=$b&pending=1&$window"
Check 'event is still pending for another consumer' ($r.Status -eq 200 -and ($r.Body.events.id -contains $id))

$r = Post-Api '/api/consume' @{ consumer = $b; ids = @($id, 999999999) }
Check 'bulk consume marks known ids and lists unknown ids' ($r.Status -eq 200 -and ($r.Body.consumed -contains $id) -and ($r.Body.unknown -contains 999999999))

$r = Post-Api '/api/consume' @{ consumer = $b; ids = @($id) }
Check 'bulk consume again reports already consumed' ($r.Status -eq 200 -and ($r.Body.already -contains $id) -and $r.Body.consumed.Count -eq 0)

$r = Post-Api "/api/events/$id/consume" @{ consumer = $c }
Check 'single consume marks the event' ($r.Status -eq 200 -and ($r.Body.consumed -contains $id))

$r = Post-Api '/api/events/999999999/consume' @{ consumer = $c }
Check 'single consume of unknown event is 404' ($r.Status -eq 404)

$r = Get-Api "/api/events/$id"
Check 'get by id lists the three consumers' ($r.Status -eq 200 -and @($r.Body.consumers).Count -eq 3)

# Notion
function Send-Notion($body, $signature) {
    $headers = @{}
    if ($signature) { $headers['x-notion-signature'] = "sha256=$signature" }
    try {
        $r = Invoke-WebRequest "$BaseUrl/hooks/notion" -Method Post -Body $body -ContentType 'application/json' `
            -Headers $headers -UseBasicParsing
        return @{ Status = [int]$r.StatusCode; Body = ($r.Content | ConvertFrom-Json) }
    } catch {
        return @{ Status = [int]$_.Exception.Response.StatusCode; Body = $null }
    }
}

$notionId = [guid]::NewGuid().ToString()
$notionBody = @{
    id = $notionId; timestamp = (Get-Date).ToUniversalTime().ToString('o'); type = 'page.properties_updated'
    attempt_number = 1; entity = @{ id = [guid]::NewGuid().ToString(); type = 'page' }; data = @{}
} | ConvertTo-Json -Compress -Depth 5

if ($NotionSecret) {
    $r = Send-Notion $notionBody (Sign $NotionSecret $notionBody)
    Check 'notion: valid signed event is accepted' ($r.Status -eq 200 -and -not $r.Body.duplicate)

    $r = Send-Notion $notionBody (Sign $NotionSecret $notionBody)
    Check 'notion: same event id again is a duplicate' ($r.Status -eq 200 -and $r.Body.duplicate)

    $r = Send-Notion $notionBody ('0' * 64)
    Check 'notion: bad signature is rejected (401)' ($r.Status -eq 401)

    $r = Send-Notion '{"verification_token":"secret_abcdefghijklmnopqrstuvwxyz0123"}' $null
    Check 'notion: unsigned handshake is rejected when the secret is set (401)' ($r.Status -eq 401)

    $r = Get-Api '/api/events?source=notion&limit=1'
    $n = $r.Body.events | Select-Object -First 1
    Check 'notion: event type and action come from the dotted type' ($n.delivery_id -eq $notionId -and $n.event_type -eq 'page' -and $n.action -eq 'properties_updated')
} else {
    $r = Send-Notion '{"verification_token":"secret_abcdefghijklmnopqrstuvwxyz0123"}' $null
    Check 'notion: handshake is answered without a secret' ($r.Status -eq 200 -and $r.Body.handshake)

    $r = Send-Notion $notionBody $null
    Check 'notion: an event without a secret is rejected (503)' ($r.Status -eq 503)

    $r = Send-Notion '{"verification_token":"secret_abcdefghijklmnopqrstuvwxyz0123","x":1}' $null
    Check 'notion: a handshake with extra fields is rejected (503)' ($r.Status -eq 503)

    $r = Get-Api '/api/events?source=notion&limit=5'
    Check 'notion: the handshake stores nothing' ($r.Status -eq 200 -and @($r.Body.events).Count -eq 0)
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
