$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')
Describe 'Online search through the desktop proxy' {
    BeforeAll {
        $script:runtime=New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        # The isolated copy supplies deterministic, deliberately slow provider
        # metadata. No CI network request and no production endpoint override.
        $module=Join-Path $runtime.Root 'MusicServer.Search.psm1'
        @'
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec)
    Start-Sleep -Milliseconds 2200
    return ('{"code":200,"result":{"songs":[{"id":777001,"name":"Fixture Lake","artists":[{"name":"Fixture Artist"}],"album":{"name":"Reflections"},"duration":120000}]}}' | ConvertFrom-Json)
}
function Search-BilibiliCandidates {
    param($Config,$Track,$Query,$Limit,$TimeoutSeconds)
    Start-Sleep -Milliseconds 400
    return [pscustomobject]@{Candidates=@([pscustomobject]@{bvid='BV1xx411c7mD';title='Fixture Bili';duration=120;metadata=[pscustomobject]@{uploader='Fixture UP'}});Blocked=$false;Error=''}
}
'@ | Add-Content -LiteralPath $module -Encoding UTF8
        Start-MusicServerFixtureServices -Fixture $script:runtime -WithUi
        $script:base="http://127.0.0.1:$($runtime.UiPort)"
    }
    AfterAll {
        if ($runtime) { Remove-MusicServerRuntimeFixture -Fixture $runtime }
    }
    It 'keeps health responsive during a provider request and supports like-to-download without daily seeds' {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $job=Invoke-RestMethod "$base/api/search" -Method Post -ContentType 'application/json' -Body '{"query":"Fixture Lake"}' -TimeoutSec 5
        $timer.Elapsed.TotalSeconds | Should BeLessThan 2
        $timer.Restart()
        (Invoke-RestMethod "$base/api/providers/status" -TimeoutSec 5).items | Should Not BeNullOrEmpty
        $timer.Elapsed.TotalSeconds | Should BeLessThan 2
        $deadline=[DateTime]::UtcNow.AddSeconds(18)
        do {
            $result=Invoke-RestMethod "$base/api/search/$($job.id)" -TimeoutSec 5
            if ($result.state -ne 'RUNNING') { break }
            Start-Sleep -Milliseconds 300
        } while ([DateTime]::UtcNow -lt $deadline)
        $result.state | Should Be DONE
        @($result.items).Count | Should Be 1
        $item=$result.items[0]
        $item.title | Should Be 'Fixture Lake'
        $like=Invoke-RestMethod "$base/api/tracks/$($item.track_id)/like" -Method Post -ContentType 'application/json' -Body '{}'
        $like.liked | Should Be $true
        $like.wanted.state | Should Be WANTED
        (Invoke-RestMethod "$base/api/search/$($job.id)").items[0].liked | Should Be $true
        (Invoke-WebRequest "$base/pond-water.js" -UseBasicParsing).StatusCode | Should Be 200
    }
    It 'uses downloaded audio for both current and earlier unindexed bindings' {
        foreach ($legacy in @($false,$true)) {
            $cfg=$runtime.Config
            Connect-MusicServerDatabase -DbPath (Join-Path $cfg.StateDir 'musicserver.db') -SqliteExe $cfg.Sqlite
            $track=New-CanonicalTrack -Title "Downloaded $legacy" -Artist Fixture
            $name="published-$legacy.mp3"
            $path=Join-Path $cfg.MusicDir $name
            [IO.File]::WriteAllBytes($path,(New-Object byte[] 4096))
            $track.status='LOCAL'
            if (-not $legacy) { $track.local_song_id=Get-MusicServerLocalIdentity -File $path }
            Save-CanonicalTrackDb -Track $track | Out-Null
            Save-RecommendationFileDb -FileName $name -TrackId $track.id -Date (Get-TodayDate) -Title $track.title -Artist Fixture -SeedSource wanted_worker | Out-Null
            $details=Invoke-RestMethod "$base/api/tracks/$($track.id)" -TimeoutSec 5
            $details.playback_source.type | Should Be local
            $request=[Net.HttpWebRequest]::Create($base+$details.playback_source.url)
            $request.Timeout=10000; $request.AddRange(0,99)
            $response=$request.GetResponse()
            try { [int]$response.StatusCode | Should Be 206; $response.ContentLength | Should Be 100 } finally { $response.Dispose() }
        }
    }
    It 'rejects invalid search bodies through the shared input contract' {
        $response=Invoke-MusicServerFragmentedRequest -Port $runtime.UiPort -Path '/api/search' -Method POST -Fragments @('{"query":{}}')
        $response.Status | Should Be 400
    }
    It 'passes source selection through the API and uses the same like-download transaction for Bilibili' {
        $job=Invoke-RestMethod "$base/api/search" -Method Post -ContentType 'application/json' -Body '{"query":"Fixture Lake","source":"bilibili"}' -TimeoutSec 5
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        do {
            $result=Invoke-RestMethod "$base/api/search/$($job.id)" -TimeoutSec 5
            if ($result.state -ne 'RUNNING') { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        $result.state | Should Be DONE
        $result.source | Should Be bilibili
        $result.items[0].title | Should Be 'Fixture Bili'
        $like=Invoke-RestMethod "$base/api/tracks/$($result.items[0].track_id)/like" -Method Post -ContentType application/json -Body '{}'
        $like.wanted.state | Should Be WANTED
        $details=Invoke-RestMethod "$base/api/tracks/$($result.items[0].track_id)"
        $details.track.download_candidates[0].bvid | Should Be BV1xx411c7mD
    }
}
