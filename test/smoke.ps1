# Smoke test for the inbox: receive, store, retrieve, push, settle, clean up.
# Usage: .\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token <INBOX_TOKEN> -LinearSecret <LINEAR_WEBHOOK_SECRET> [-NotionSecret <NOTION_WEBHOOK_SECRET>] [-Local]
# Without -NotionSecret, the Worker must have no NOTION_WEBHOOK_SECRET, and the test checks the Notion handshake.
# With -NotionSecret, the test checks signed Notion events.
# With -Local, the Worker must run on this machine with `wrangler dev --test-scheduled`.
# The test then changes times in the local D1 to check the settled rule and the daily cleanup.
param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $LinearSecret,
    [string] $NotionSecret,
    [switch] $Local
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

# Settled
# Runs SQL on the local D1 of `wrangler dev` and returns the result rows.
function Invoke-LocalSql($sql) {
    Push-Location (Join-Path $PSScriptRoot '..')
    try {
        $out = & npx wrangler d1 execute webhook-hub --local --json --command $sql 2>$null
        if ($LASTEXITCODE -ne 0) { throw "wrangler d1 execute failed: $sql" }
        return (($out -join "`n") | ConvertFrom-Json)[0].results
    } finally { Pop-Location }
}

function IsoUtc($offset) { [DateTime]::UtcNow.Add($offset).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }

$d = "smoke-d-$run"
$r = Get-Api "/api/events?consumer=$d&pending=1&$window"
Check 'event consumed less than 1 hour ago is still pending for another consumer' ($r.Status -eq 200 -and ($r.Body.events.id -contains $id))

if ($Local) {
    $twoHoursAgo = IsoUtc ([TimeSpan]::FromHours(-2))
    Invoke-LocalSql "UPDATE consumptions SET consumed_at = '$twoHoursAgo' WHERE event_id = $id AND consumer = '$a'" | Out-Null

    $r = Get-Api "/api/events?consumer=$d&pending=1&$window"
    Check 'settled event (first consume 1 hour ago or more) is not pending' ($r.Status -eq 200 -and -not ($r.Body.events.id -contains $id))

    $r = Get-Api "/api/events?consumer=$d&pending=1&settled=1&$window"
    Check 'settled=1 returns the settled event' ($r.Status -eq 200 -and ($r.Body.events.id -contains $id))
} else {
    Write-Host 'SKIP  settled rule (needs -Local)' -ForegroundColor Yellow
}

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
    # The newest Notion event before the handshake. A database can hold events from a signed run.
    $before = @((Get-Api '/api/events?source=notion&limit=1').Body.events) | Select-Object -First 1
    $beforeId = if ($before) { $before.id } else { 0 }

    $r = Send-Notion '{"verification_token":"secret_abcdefghijklmnopqrstuvwxyz0123"}' $null
    Check 'notion: handshake is answered without a secret' ($r.Status -eq 200 -and $r.Body.handshake)

    $r = Send-Notion $notionBody $null
    Check 'notion: an event without a secret is rejected (503)' ($r.Status -eq 503)

    $r = Send-Notion '{"verification_token":"secret_abcdefghijklmnopqrstuvwxyz0123","x":1}' $null
    Check 'notion: a handshake with extra fields is rejected (503)' ($r.Status -eq 503)

    $r = Get-Api "/api/events?source=notion&after=$beforeId&limit=5"
    Check 'notion: the handshake stores nothing' ($r.Status -eq 200 -and @($r.Body.events).Count -eq 0)
}

# Listen
$r = Get-Api "/listen?consumer=smoke-listen-$run" $false
Check 'listen without token is rejected (401)' ($r.Status -eq 401)

$r = Get-Api '/listen?consumer=Bad%20Name'
Check 'listen with an invalid consumer name is rejected (400)' ($r.Status -eq 400)

# Waits for one text message. Returns $null after the timeout.
function Receive-Message($ws, $timeoutMs) {
    if (-not $script:pendingReceive) {
        $script:receiveBuffer = [ArraySegment[byte]]::new([byte[]]::new(65536))
        $script:pendingReceive = $ws.ReceiveAsync($script:receiveBuffer, [Threading.CancellationToken]::None)
    }
    if (-not $script:pendingReceive.Wait($timeoutMs)) { return $null }
    $result = $script:pendingReceive.Result
    $script:pendingReceive = $null
    if ($result.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($script:receiveBuffer.Array, 0, $result.Count)
    return ($text | ConvertFrom-Json)
}

$listener = "smoke-listen-$run"
$ws = [Net.WebSockets.ClientWebSocket]::new()
$ws.Options.SetRequestHeader('Authorization', "Bearer $Token")
$wsUrl = ($BaseUrl -replace '^http', 'ws') + "/listen?consumer=$listener"
$connected = $false
try { $connected = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(10000) } catch { $connected = $false }
Check 'listen with a valid token opens a WebSocket' ($connected -and $ws.State -eq 'Open')

if ($connected) {
    $m = Receive-Message $ws 10000
    Check 'listen sends hello with the consumer name' ($m.kind -eq 'hello' -and $m.consumer -eq $listener)

    $pushDelivery = [guid]::NewGuid().ToString()
    $pushBody = $body.Replace('"MAT-47"', '"MAT-PUSH"').Replace("$now", "$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())")
    $pushSig = Sign $LinearSecret $pushBody
    $r = Send $pushBody $pushSig $pushDelivery
    Check 'webhook with an open listener is accepted' ($r.Status -eq 200 -and -not $r.Body.duplicate)

    $m = Receive-Message $ws 10000
    $e = $m.event
    Check 'listen pushes the new event' ($m.kind -eq 'event' -and $e.delivery_id -eq $pushDelivery -and $e.payload.data.identifier -eq 'MAT-PUSH')

    $r = Get-Api "/api/events?after=$($e.id - 1)&limit=1&payload=1"
    $apiEvent = $r.Body.events | Select-Object -First 1
    $pushNames = ($e.PSObject.Properties.Name | Sort-Object) -join ','
    $apiNames = ($apiEvent.PSObject.Properties.Name | Sort-Object) -join ','
    Check 'pushed event has the shape of GET /api/events?payload=1' ($apiEvent.id -eq $e.id -and $pushNames -eq $apiNames -and $apiEvent.received_at -eq $e.received_at)

    $r = Send $pushBody $pushSig $pushDelivery
    $m = Receive-Message $ws 2000
    Check 'a duplicate delivery is not pushed' ($r.Status -eq 200 -and $r.Body.duplicate -and $null -eq $m)

    $ws.Abort()
}
$ws.Dispose()

# Cleanup (daily cron)
if ($Local) {
    $oldConsumer = "smoke-old-$run"
    $eightDaysAgo = IsoUtc ([TimeSpan]::FromDays(-8))
    $sixDaysAgo = IsoUtc ([TimeSpan]::FromDays(-6))
    Invoke-LocalSql ("INSERT INTO events (source, delivery_id, payload, received_at) VALUES " +
        "('smoke', 'old-$run', '{}', '$eightDaysAgo'), ('smoke', 'recent-$run', '{}', '$sixDaysAgo'); " +
        "INSERT INTO consumptions (event_id, consumer) SELECT id, '$oldConsumer' FROM events WHERE source = 'smoke' AND delivery_id IN ('old-$run', 'recent-$run')") | Out-Null

    try {
        $r = Invoke-WebRequest "$BaseUrl/__scheduled?cron=17+3+*+*+*" -UseBasicParsing
        $status = [int]$r.StatusCode
    } catch { $status = 0 }
    Check 'cron runs with --test-scheduled' ($status -eq 200)

    $rows = Invoke-LocalSql "SELECT delivery_id FROM events WHERE source = 'smoke' AND delivery_id IN ('old-$run', 'recent-$run')"
    Check 'cron deletes the event received 7 days ago or more' (-not (@($rows).delivery_id -contains "old-$run"))
    Check 'cron keeps the event received less than 7 days ago' (@($rows).delivery_id -contains "recent-$run")

    $rows = Invoke-LocalSql "SELECT COUNT(*) AS n FROM consumptions WHERE consumer = '$oldConsumer'"
    Check 'cron deletes the consume rows of the deleted event' (@($rows)[0].n -eq 1)

    Invoke-LocalSql "DELETE FROM consumptions WHERE consumer = '$oldConsumer'; DELETE FROM events WHERE source = 'smoke' AND delivery_id = 'recent-$run'" | Out-Null
} else {
    Write-Host 'SKIP  daily cleanup (needs -Local)' -ForegroundColor Yellow
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
