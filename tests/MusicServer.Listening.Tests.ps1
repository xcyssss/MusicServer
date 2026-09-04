<#
    Listening statistics behavior tests.

    These tests use the public SQLite state interface. The implementation must
    keep the aggregate and its session deduplication in the MusicServer state
    database; Navidrome is not involved in the write path.
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force

$script:T = [pscustomobject]@{
    Root = $null
    ApiProcs = @()
    TestRoots = @()
}

function New-ListeningTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mslisten_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'DailyMix_data\state') -Force
    $script:T.Root = $root
    $script:T.TestRoots += $root
    return $root
}

function Initialize-ListeningTestDatabase {
    param([Parameter(Mandatory)][string]$Root)
    $config = New-MusicServerConfig -Root $Root
    Initialize-MusicServerState -Config $config
    $dbPath = Join-Path $config.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $config.Sqlite
    Initialize-MusicServerSchema
}

function Invoke-ListeningFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Start-ListeningApi {
    param([Parameter(Mandatory)][string]$Root)
    $port = Invoke-ListeningFreePort
    $prefix = "http://127.0.0.1:$port/"
    $outFile = Join-Path $Root 'listening_api.out.log'
    $errFile = Join-Path $Root 'listening_api.err.log'
    $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ProjectRoot 'music_api.ps1'), '-Prefix', $prefix, '-Root', $Root)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $script:T.ApiProcs += $proc
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $out = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($out -match 'API v2 ready') { return [pscustomobject]@{ Process = $proc; BaseUrl = $prefix.TrimEnd('/') } }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    $out = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
    throw "Listening API did not start. stdout=$out stderr=$err"
}

function Stop-ListeningApi {
    foreach ($proc in @($script:T.ApiProcs)) {
        try {
            if ($proc -and -not $proc.HasExited) {
                & cmd.exe /c "taskkill /PID $($proc.Id) /T /F" 6>&1 | Out-Null
                $proc.WaitForExit(5000) | Out-Null
            }
        } catch {}
        try { if ($proc) { $proc.Dispose() | Out-Null } } catch {}
    }
    $script:T.ApiProcs = @()
}

function Invoke-ListeningHttp {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$Body = ''
    )
    $status = -1
    $text = ''
    try {
        $request = [System.Net.HttpWebRequest]::Create($BaseUrl.TrimEnd('/') + $Path)
        $request.Method = $Method
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 20000
        $request.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        if ($request.GetType().GetProperty('ContentLength64')) { $request.ContentLength64 = $bytes.Length } else { $request.ContentLength = $bytes.Length }
        if ($bytes.Length -gt 0) {
            $stream = $request.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $status = [int]$response.StatusCode
        $response.Dispose()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            try {
                $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $status = [int]$response.StatusCode
                $response.Dispose()
            } catch {}
        }
    }
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}

function New-ListeningNavidromeFixture {
    param([Parameter(Mandatory)][string]$Root)
    $config = New-MusicServerConfig -Root $Root
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $config.NdDb) -Force
    $null = New-Item -ItemType Directory -Path $config.MusicDir -Force
    $one = Join-Path $config.MusicDir 'One.mp3'
    $two = Join-Path $config.MusicDir 'Two.mp3'
    [IO.File]::WriteAllBytes($one, (New-Object byte[] 4))
    [IO.File]::WriteAllBytes($two, (New-Object byte[] 4))
    # Navidrome stores media_file.path relative to MusicFolder.
    $oneSql = ConvertTo-MusicServerSqlLiteral 'One.mp3'
    $twoSql = ConvertTo-MusicServerSqlLiteral 'Two.mp3'
    $sql = @"
CREATE TABLE media_file (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    duration REAL NOT NULL DEFAULT 0,
    track_number INTEGER NOT NULL DEFAULT 0,
    created_at TEXT,
    updated_at TEXT,
    missing BOOLEAN NOT NULL DEFAULT 0
);
INSERT INTO media_file (id, path, title, album, artist, duration, track_number, created_at, updated_at, missing)
VALUES ('mf-one', $oneSql, 'One', 'Album', 'Artist One', 180, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0);
INSERT INTO media_file (id, path, title, album, artist, duration, track_number, created_at, updated_at, missing)
VALUES ('mf-two', $twoSql, 'Two', 'Album', 'Artist Two', 180, 2, '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z', 0);
"@
    & $config.Sqlite $config.NdDb $sql 2>&1 | Out-Null
    return $config
}

function Remove-ListeningTestRoots {
    Stop-ListeningApi
    foreach ($root in @($script:T.TestRoots)) {
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:T.Root = $null
    $script:T.ApiProcs = @()
    $script:T.TestRoots = @()
}

Describe 'MusicServer listening statistics' {
    BeforeEach {
        $root = New-ListeningTestRoot
        Initialize-ListeningTestDatabase -Root $root
    }

    AfterEach {
        Remove-ListeningTestRoots
    }

    It 'counts one first play, ignores repeated events in the same session, and counts a replay' {
        $first = Record-ListeningPlayDb -Identity 'na-test-track' -TrackId 'track-test' -LibraryId 'library-test' -SessionId 'session-1' -Now '2026-09-04T00:00:00.0000000Z'
        [int]$first.play_count | Should Be 1
        $first.first_played_at | Should Be '2026-09-04T00:00:00.0000000Z'
        $first.last_played_at | Should Be '2026-09-04T00:00:00.0000000Z'

        $duplicate = Record-ListeningPlayDb -Identity 'na-test-track' -TrackId 'track-test' -LibraryId 'library-test' -SessionId 'session-1' -Now '2026-09-04T00:01:00.0000000Z'
        [int]$duplicate.play_count | Should Be 1
        $duplicate.counted | Should Be $false

        $replay = Record-ListeningPlayDb -Identity 'na-test-track' -TrackId 'track-test' -LibraryId 'library-test' -SessionId 'session-2' -Now '2026-09-04T00:02:00.0000000Z'
        [int]$replay.play_count | Should Be 2
        $replay.counted | Should Be $true
        $replay.last_played_at | Should Be '2026-09-04T00:02:00.0000000Z'
    }

    It 'sorts most played and only returns current local tracks for rediscovery' {
        $library = @(
            [pscustomobject]@{ id = 'library-one'; track_id = 'track-one'; listening_identity = 'local-one'; title = 'One'; artist = 'Artist'; album = ''; duration = 180; stream_url = '/api/library/library-one/stream'; lyrics_url = '' },
            [pscustomobject]@{ id = 'library-two'; track_id = 'track-two'; listening_identity = 'local-two'; title = 'Two'; artist = 'Artist'; album = ''; duration = 180; stream_url = '/api/library/library-two/stream'; lyrics_url = '' },
            [pscustomobject]@{ id = 'library-recent'; track_id = 'track-recent'; listening_identity = 'local-recent'; title = 'Recent'; artist = 'Artist'; album = ''; duration = 180; stream_url = '/api/library/library-recent/stream'; lyrics_url = '' },
            [pscustomobject]@{ id = 'library-never'; track_id = 'track-never'; listening_identity = 'local-never'; title = 'Never'; artist = 'Artist'; album = ''; duration = 180; stream_url = '/api/library/library-never/stream'; lyrics_url = '' }
        )
        [void](Record-ListeningPlayDb -Identity 'local-one' -TrackId 'track-one' -LibraryId 'library-one' -SessionId 'one-1' -Now '2026-01-01T00:00:00.0000000Z')
        [void](Record-ListeningPlayDb -Identity 'local-two' -TrackId 'track-two' -LibraryId 'library-two' -SessionId 'two-1' -Now '2026-01-02T00:00:00.0000000Z')
        [void](Record-ListeningPlayDb -Identity 'local-two' -TrackId 'track-two' -LibraryId 'library-two' -SessionId 'two-2' -Now '2026-01-03T00:00:00.0000000Z')
        [void](Record-ListeningPlayDb -Identity 'local-recent' -TrackId 'track-recent' -LibraryId 'library-recent' -SessionId 'recent-1' -Now '2026-09-03T23:30:00.0000000Z')
        [void](Record-ListeningPlayDb -Identity 'missing-from-library' -TrackId 'track-ghost' -LibraryId 'library-ghost' -SessionId 'ghost-1' -Now '2025-01-01T00:00:00.0000000Z')

        $overview = Get-ListeningOverviewDb -LibraryItems $library -AsOf ([DateTime]::Parse('2026-09-04T00:00:00.0000000Z')) -RediscoverLimit 5

        $overview.most_played.Count | Should Be 3
        $overview.most_played[0].id | Should Be 'library-two'
        [int]$overview.most_played[0].play_count | Should Be 2
        $overview.most_played[1].id | Should Be 'library-recent'
        $overview.most_played[2].id | Should Be 'library-one'
        (@($overview.rediscover | Where-Object { $_.id -eq 'library-recent' })).Count | Should Be 0
        (@($overview.rediscover | Where-Object { $_.id -eq 'library-never' })).Count | Should Be 1
        (@($overview.rediscover | Where-Object { $_.id -eq 'library-ghost' })).Count | Should Be 0
    }

    It 'exposes the listening JSON contract and chooses random songs from the local library' {
        $config = New-ListeningNavidromeFixture -Root $script:T.Root
        $api = Start-ListeningApi -Root $script:T.Root
        try {
            $stats = Invoke-ListeningHttp -BaseUrl $api.BaseUrl -Method 'GET' -Path '/api/listening/stats'
            $stats.Status | Should Be 200
            $stats.Json.most_played | Should BeNullOrEmpty
            $stats.Json.rediscover.Count | Should Be 2
            @('library-mf-one', 'library-mf-two') -contains [string]$stats.Json.rediscover[0].id | Should Be $true

            $random = Invoke-ListeningHttp -BaseUrl $api.BaseUrl -Method 'GET' -Path '/api/listening/random'
            $random.Status | Should Be 200
            @('library-mf-one', 'library-mf-two') -contains [string]$random.Json.id | Should Be $true
            $random.Json.stream_url | Should Match '/api/library/'

            $play = Invoke-ListeningHttp -BaseUrl $api.BaseUrl -Method 'POST' -Path '/api/library/library-mf-one/play' -Body '{"session_id":"api-session-1"}'
            $play.Status | Should Be 200
            $play.Json.counted | Should Be $true
            [int]$play.Json.play_count | Should Be 1

            $duplicate = Invoke-ListeningHttp -BaseUrl $api.BaseUrl -Method 'POST' -Path '/api/library/library-mf-one/play' -Body '{"session_id":"api-session-1"}'
            $duplicate.Status | Should Be 200
            $duplicate.Json.counted | Should Be $false
            [int]$duplicate.Json.play_count | Should Be 1

            $after = Invoke-ListeningHttp -BaseUrl $api.BaseUrl -Method 'GET' -Path '/api/listening/stats'
            $after.Status | Should Be 200
            $after.Json.most_played[0].id | Should Be 'library-mf-one'
            $after.Json.most_played[0].title | Should Be 'One'
            $after.Json.most_played[0].artist | Should Be 'Artist One'
        } finally {
            Stop-ListeningApi
        }
    }

    It 'keeps the listening PowerShell entry points parseable on Windows PowerShell 5.1' {
        foreach ($relativePath in @('MusicServer.State.psm1', 'music_api.ps1', 'start_musicserver_ui.ps1')) {
            $path = Join-Path $ProjectRoot $relativePath
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should Be 0 -Because "$relativePath must have no parser errors"
        }
    }
}
