# Real PS5.1 sockets and isolated runtime; no external lyrics service or media.
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'Bounded media I/O runtime' {
    BeforeEach {
        $script:MediaFixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        $script:MediaRequests = @()
        $cfg = $script:MediaFixture.Config
        Initialize-MusicServerDatabase -DbPath (Join-Path $cfg.StateDir 'musicserver.db') -SqliteExe $cfg.Sqlite
        Initialize-MusicServerSchema
        Invoke-MusicServerSqlNonQuery -Query @"
INSERT INTO canonical_tracks (id, title, identifiers_json) VALUES ('slow', 'Slow lyrics', '[{"type":"netease","value":"1"}]');
INSERT INTO daily_recommendations (date, rank, track_id, netease_id, created_at) VALUES ('$(Get-TodayDate)', 1, 'slow', '1', 'fixture');
"@
        # Replace only the external provider in this disposable copy. The marker
        # proves the real lyrics handler reached slow I/O before probing health.
        $path = Join-Path $script:MediaFixture.Root 'start_musicserver_ui.ps1'
        $source = [IO.File]::ReadAllText($path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-NetEaseLyricsById' }, $false)
        $replacement = @'
function Get-NetEaseLyricsById {
    param([string]$SongId)
    [IO.File]::WriteAllText((Join-Path $Root ('slow-' + [guid]::NewGuid().ToString('N'))), 'started')
    Start-Sleep -Seconds 4
    return '[00:00.00]fixture lyric'
}
'@
        $source = $source.Substring(0, $fn.Extent.StartOffset) + $replacement + $source.Substring($fn.Extent.EndOffset)
        [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($true))
        # Large local file makes an unread TCP response block its media slot.
        $file = Join-Path $cfg.MusicDir 'test.wav'
        $stream = [IO.File]::Create($file)
        try { $stream.SetLength(32MB) } finally { $stream.Dispose() }
        [IO.File]::WriteAllText((Join-Path $cfg.MusicDir 'test.lrc'), '[00:00.00]local lyric')
        Start-MusicServerFixtureServices -Fixture $script:MediaFixture -WithUi
        $script:MediaBase = "http://127.0.0.1:$($script:MediaFixture.UiPort)"
    }
    AfterEach {
        Get-Content (Join-Path $script:MediaFixture.Root 'logs/musicserver-ui.log') -ErrorAction SilentlyContinue | Select-Object -Last 8 | ForEach-Object { Write-Host $_ }
        Get-Content (Join-Path $script:MediaFixture.Root 'ui.err.log') -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        foreach ($request in $script:MediaRequests) { try { $request.Abort() } catch {} }
        Remove-MusicServerRuntimeFixture -Fixture $script:MediaFixture
    }

    It 'keeps health and heartbeat responsive during slow lyrics and bounds admission' {
        $pending = @()
        foreach ($i in 1..3) {
            $request = [Net.HttpWebRequest]::Create($script:MediaBase + '/api/tracks/slow/lyrics')
            $request.ConnectionGroupName = "media-$i"
            $request.Timeout = 15000
            $script:MediaRequests += $request
            $pending += $request.BeginGetResponse($null, $null)
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $started = @(Get-ChildItem -LiteralPath $script:MediaFixture.Root -Filter 'slow-*').Count
            if ($started -eq 3) { break }
            Start-Sleep -Milliseconds 25
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($started -ne 3 -and $pending[0].IsCompleted) {
            $response = $script:MediaRequests[0].EndGetResponse($pending[0])
            $reader = [IO.StreamReader]::new($response.GetResponseStream())
            try { Write-Host $reader.ReadToEnd() } finally { $reader.Dispose(); $response.Dispose() }
        }
        $started | Should Be 3
        $id = (Invoke-RestMethod ($script:MediaBase + '/api/library')).items[0].id
        $audio = [Net.HttpWebRequest]::Create($script:MediaBase + "/api/library/$id/stream")
        $audio.Timeout = 2000
        $script:MediaRequests += $audio
        $audioResponse = $audio.GetResponse()
        [int]$audioResponse.StatusCode | Should Be 200
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $health = Invoke-RestMethod ($script:MediaBase + '/health') -TimeoutSec 2
        $health.status | Should Be 'ok'
        Invoke-WebRequest ($script:MediaBase + '/ui/heartbeat?id=media-test') -Method POST -UseBasicParsing -TimeoutSec 2 | Out-Null
        ($watch.ElapsedMilliseconds -lt 1500) | Should Be $true
        $status = 0
        try { Invoke-WebRequest ($script:MediaBase + '/api/tracks/slow/lyrics') -UseBasicParsing -TimeoutSec 2 | Out-Null }
        catch { $status = [int]$_.Exception.Response.StatusCode }
        $status | Should Be 503
        $latencies = @()
        foreach ($sample in 1..30) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            (Invoke-RestMethod ($script:MediaBase + '/health') -TimeoutSec 2).status | Should Be 'ok'
            $latencies += $timer.Elapsed.TotalMilliseconds
        }
        $ordered = @($latencies | Sort-Object)
        Write-Host ("MEDIA_HEALTH samples=30 p95_ms={0:N2}" -f $ordered[28])
        $audioResponse.Dispose()
        foreach ($i in 0..2) {
            $response = $script:MediaRequests[$i].EndGetResponse($pending[$i])
            $reader = [IO.StreamReader]::new($response.GetResponseStream())
            try { (($reader.ReadToEnd() | ConvertFrom-Json).available) | Should Be $true }
            finally { $reader.Dispose(); $response.Dispose() }
        }
    }

    It 'serves Range and 416 while an audio client stops reading and recovers after disconnect' {
        $library = Invoke-RestMethod ($script:MediaBase + '/api/library') -TimeoutSec 10
        $id = [string]$library.items[0].id
        $tcp = [Net.Sockets.TcpClient]::new()
        try {
            $tcp.ReceiveBufferSize = 1024
            $tcp.Connect('127.0.0.1', $script:MediaFixture.UiPort)
            $bytes = [Text.Encoding]::ASCII.GetBytes("GET /api/library/$id/stream HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
            $tcp.GetStream().Write($bytes, 0, $bytes.Length)
            Start-Sleep -Milliseconds 200
            $watch = [Diagnostics.Stopwatch]::StartNew()
            (Invoke-RestMethod ($script:MediaBase + '/health') -TimeoutSec 2).status | Should Be 'ok'
            ($watch.ElapsedMilliseconds -lt 1500) | Should Be $true
            $request = [Net.HttpWebRequest]::Create($script:MediaBase + "/api/library/$id/stream")
            $request.Timeout = 10000
            $request.AddRange(0, 99)
            $response = $request.GetResponse()
            try { [int]$response.StatusCode | Should Be 206; $response.ContentLength | Should Be 100 }
            finally { $response.Dispose() }
            $request = [Net.HttpWebRequest]::Create($script:MediaBase + "/api/library/$id/stream")
            $request.AddRange([long]64MB)
            $status = 0
            try { $response = $request.GetResponse(); $response.Dispose() }
            catch {
                $errorResponse = $_.Exception.InnerException.Response
                $status = [int]$errorResponse.StatusCode
                if ($errorResponse) { $errorResponse.Dispose() } else { throw }
            }
            $status | Should Be 416
        } finally { $tcp.Dispose() }
        (Invoke-RestMethod ($script:MediaBase + "/api/library/$id/lyrics") -TimeoutSec 10).available | Should Be $true
        $extra = Join-Path $script:MediaFixture.Config.MusicDir 'new-download.wav'
        [IO.File]::WriteAllBytes($extra, [byte[]]@(0, 1))
        (Invoke-RestMethod ($script:MediaBase + '/api/library')).total | Should Be 1
        (Invoke-RestMethod ($script:MediaBase + '/api/library?refresh=1')).total | Should Be 2
        Remove-Item -LiteralPath $extra
        (Invoke-RestMethod ($script:MediaBase + '/api/library?refresh=1')).total | Should Be 1
    }
}
