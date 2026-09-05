$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'MusicServer JSON request reader' {
    BeforeEach { Import-Module (Join-Path $ProjectRoot 'MusicServer.Http.psm1') -Force }

    It 'rejects truncated and invalid UTF-8 bodies before JSON parsing' {
        foreach ($case in @(
            @{ Bytes = [Text.Encoding]::UTF8.GetBytes('{'); Length = 2; Code = 'INCOMPLETE_BODY' },
            @{ Bytes = [byte[]]@(123,34,120,34,58,34,255,34,125); Length = 9; Code = 'INVALID_JSON' }
        )) {
            $stream = New-Object IO.MemoryStream(,$case.Bytes)
            try {
                $request = [pscustomobject]@{ Headers = @{}; ContentLength64 = $case.Length; InputStream = $stream }
                $code = ''
                try { Read-MusicServerJsonRequest -Request $request | Out-Null } catch { $code = $_.Exception.Data['ErrorCode'] }
                $code | Should Be $case.Code
            } finally { $stream.Dispose() }
        }
    }

    It 'accepts empty bodies and a JSON object exactly at the byte limit' {
        foreach ($text in @('', ('{"note":"' + ('x' * (65536 - 11)) + '"}'))) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            $stream = New-Object IO.MemoryStream(,$bytes)
            try {
                $request = [pscustomobject]@{ Headers = @{}; ContentLength64 = $bytes.Length; InputStream = $stream }
                $result = Read-MusicServerJsonRequest -Request $request
                $result.Text | Should Be $text
                $result.Bytes.Length | Should Be $bytes.Length
            } finally { $stream.Dispose() }
        }
    }
}

Describe 'MusicServer bounded JSON over real API and UI proxy sockets' {
    BeforeEach {
        $script:HttpFixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        $script:HttpTrack = New-CanonicalTrack -Title 'Body test' -Artist 'Fixture' -Status 'REMOTE'
        Save-CanonicalTrackDb -Track $script:HttpTrack | Out-Null
        Start-MusicServerFixtureServices -Fixture $script:HttpFixture -WithUi
        $script:HttpCountQuery = 'SELECT (SELECT count(*) FROM wanted_queue) + (SELECT count(*) FROM recommendation_feedback) + (SELECT count(*) FROM events) AS n;'
        $script:HttpBefore = [int](@(Invoke-MusicServerSqlJson -Query $script:HttpCountQuery)[0].n)
    }
    AfterEach { if ($script:HttpFixture) { Remove-MusicServerRuntimeFixture -Fixture $script:HttpFixture } }

    It 'accepts fragmented Unicode JSON and preserves the requested track through both services' {
        foreach ($port in @($script:HttpFixture.ApiPort, $script:HttpFixture.UiPort)) {
            $fragments = @('{"track_', ('id":"' + $script:HttpTrack.id + '","note":"'), ([string][char]0x96EA + '"}'))
            $result = Invoke-MusicServerFragmentedRequest -Port $port -Path '/api/wanted' -Fragments $fragments -FragmentDelayMs 100
            $result.Status | Should Be 202
            $result.Text | Should Match ([regex]::Escape($script:HttpTrack.id))
        }
        @(Get-WantedTracksDb).Count | Should Be 1
    }

    It 'rejects malformed, non-object, oversized, chunked and compressed requests without writes' {
        foreach ($port in @($script:HttpFixture.ApiPort, $script:HttpFixture.UiPort)) {
            foreach ($body in @('{"track_id":', '[]', 'null', ' ', '{"track_id":"x",} broken')) {
                $result = Invoke-MusicServerFragmentedRequest -Port $port -Path ("/api/tracks/$($script:HttpTrack.id)/like") -Fragments @($body)
                $result.Status | Should Be 400
                $result.Text | Should Match 'INVALID_JSON'
            }
            $large = Invoke-MusicServerFragmentedRequest -Port $port -Path '/api/wanted' -Fragments @('') -LengthOverride 65537
            $large.Status | Should Be 413
            $chunked = Invoke-MusicServerFragmentedRequest -Port $port -Path '/api/wanted' -Fragments @("2`r`n{}`r`n0`r`n`r`n") -Chunked
            $chunked.Status | Should Be 411
            $compressed = Invoke-MusicServerFragmentedRequest -Port $port -Path '/api/wanted' -ContentEncoding 'gzip'
            $compressed.Status | Should Be 415
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 5
            $health.status | Should Be 'ok'
        }
        [int](@(Invoke-MusicServerSqlJson -Query $script:HttpCountQuery)[0].n) | Should Be $script:HttpBefore
    }

    It 'bounds a stalled body and remains healthy after clients disconnect early' {
        foreach ($port in @($script:HttpFixture.ApiPort, $script:HttpFixture.UiPort)) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $stalled = Invoke-MusicServerFragmentedRequest -Port $port -Path ("/api/tracks/$($script:HttpTrack.id)/like") -Fragments @('{') -LengthOverride 2
            $stalled.Status | Should Be 408
            ($timer.Elapsed.TotalSeconds -lt 10) | Should Be $true
            # HTTP.sys may close a truncated connection without an HTTP response.
            try { Invoke-MusicServerFragmentedRequest -Port $port -Path '/api/wanted' -Fragments @('{') -LengthOverride 12 -CloseSend | Out-Null } catch {}
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 8
            $health.status | Should Be 'ok'
        }
        [int](@(Invoke-MusicServerSqlJson -Query $script:HttpCountQuery)[0].n) | Should Be $script:HttpBefore
    }
}
