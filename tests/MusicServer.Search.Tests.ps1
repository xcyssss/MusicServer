$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')
Describe 'Online search identities and state boundaries' {
    BeforeEach {
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Force
        $script:fixture=New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Search.psm1') -Force
        Initialize-OnlineSearchSchema
        $script:songs=@([pscustomobject]@{id=123456;name='湖面';artists=@([pscustomobject]@{name='测试歌手'});album=[pscustomobject]@{name='云影'};duration=203000})
        $script:searchId=[guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO online_searches(id,query,state,created_at,expires_at) VALUES(@id,'湖面','RUNNING',@now,@expires);" -Params @{id=$searchId;now=(Get-NowIso);expires=[DateTime]::UtcNow.AddSeconds(20).ToString('o')} | Out-Null
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:fixture }

    It 'rejects invalid queries and malformed or duplicated provider records' {
        (Start-OnlineMusicSearch -Config $fixture.Config -Query @{a=1}).Status | Should Be 400
        (Start-OnlineMusicSearch -Config $fixture.Config -Query ('x'*81)).Status | Should Be 400
        (Start-OnlineMusicSearch -Config $fixture.Config -Query "song`nother").Status | Should Be 400
        $bad=@{id='not-id';name='bad';artists=@(@{name='a'});duration=5000}
        $tracks=@(ConvertFrom-OnlineSearchSongs -Songs @($songs[0],$songs[0],$bad))
        $tracks.Count | Should Be 1
        $tracks[0].duration | Should Be 203
        $tracks[0].preview_sources[0].media_url | Should Be 'https://music.163.com/song/media/outer/url?id=123456.mp3'
    }

    It 'shares a daily identity and never overwrites a local binding or likes' {
        $track=@(ConvertFrom-OnlineSearchSongs -Songs $songs)[0]
        $track.status='LOCAL';$track.local_song_id='library-kept'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-LikeTrackTransactionDb -TrackId $track.id -Source 'test' | Out-Null
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @(ConvertFrom-OnlineSearchSongs -Songs $songs)
        $result=Get-OnlineMusicSearch -SearchId $searchId
        @($result.items).Count | Should Be 1
        $result.items[0].track_id | Should Be $track.id
        $result.items[0].liked | Should Be $true
        (Get-CanonicalTrackDb -TrackId $track.id).local_song_id | Should Be 'library-kept'
        @((Get-TodayRecommendationsDb)).Count | Should Be 0
    }

    It 'keeps recordings with distinct provider IDs apart even with the same title and artist' {
        $track=@(ConvertFrom-OnlineSearchSongs -Songs $songs)[0]
        Save-CanonicalTrackDb -Track $track | Out-Null
        $songs[0].id=654321
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @(ConvertFrom-OnlineSearchSongs -Songs $songs)
        $result=Get-OnlineMusicSearch -SearchId $searchId
        $result.items[0].track_id | Should Be 'track_netease_654321'
        (Get-CanonicalTrackDb -TrackId $track.id).identifiers[0].value | Should Be '123456'
        Invoke-LikeTrackTransactionDb -TrackId $result.items[0].track_id -Source 'test' | Out-Null
        (Get-WantedItemDb -TrackId $result.items[0].track_id).state | Should Be WANTED
    }

    It 'caches a completed result without starting a second search or a download' {
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @(ConvertFrom-OnlineSearchSongs -Songs $songs)
        $result=Start-OnlineMusicSearch -Config $fixture.Config -Query '湖面'
        $result.Body.id | Should Be $searchId
        @(Get-WantedTracksDb).Count | Should Be 0
    }

    It 'does not publish late results after a timed out job' {
        Invoke-MusicServerParamNonQuery -Template "UPDATE online_searches SET expires_at='2000-01-01' WHERE id=@id;" -Params @{id=$searchId} | Out-Null
        (Get-OnlineMusicSearch -SearchId $searchId).error | Should Be SEARCH_TIMEOUT
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @(ConvertFrom-OnlineSearchSongs -Songs $songs)
        (Get-OnlineMusicSearch -SearchId $searchId).state | Should Be ERROR
        @(Invoke-MusicServerSqlJson -Query 'SELECT id FROM canonical_tracks;').Count | Should Be 0
    }

    It 'honors the provider circuit and reports unavailability instead of fabricated results' {
        Mock Claim-ProviderRequest -ModuleName MusicServer.Search { $false }
        Mock Invoke-RestMethod -ModuleName MusicServer.Search { throw 'Must not search a blocked provider' }
        Invoke-OnlineMusicSearch -Config $fixture.Config -SearchId $searchId -Query '湖面'
        (Get-OnlineMusicSearch -SearchId $searchId).error | Should Be PROVIDER_UNAVAILABLE
        Assert-MockCalled Invoke-RestMethod -ModuleName MusicServer.Search -Times 0 -Exactly -Scope It
    }
    It 'keeps Bilibili identities separate and preserves a direct candidate without inventing a singer' {
        $entry=New-DownloadCandidate -Provider bilibili_search -Bvid BV1xx411c7mD -Title '湖面' -Duration 203 -Metadata ([pscustomobject]@{uploader='测试UP'})
        $track=@(ConvertFrom-BilibiliSearchCandidates -Candidates @($entry,$entry))[0]
        $track.artist | Should Be ''
        $track.preview_sources[0].uploader | Should Be '测试UP'
        $track.download_candidates[0].provider | Should Be bilibili_direct
        $track.download_candidates[0].requires_search | Should Be $false
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @($track)
        $result=Get-OnlineMusicSearch -SearchId $searchId
        $result.items[0].track_id | Should Be 'track_bilibili_BV1xx411c7mD'
        Invoke-LikeTrackTransactionDb -TrackId $track.id | Out-Null
        (Get-WantedItemDb -TrackId $track.id).state | Should Be WANTED
        (Get-CanonicalTrackDb -TrackId $track.id).download_candidates[0].bvid | Should Be BV1xx411c7mD
    }
    It 'validates sources and does not reuse the other provider cache' {
        (Start-OnlineMusicSearch -Config $fixture.Config -Query '湖面' -Source bad).Status | Should Be 400
        Save-OnlineSearchResultsDb -SearchId $searchId -Tracks @()
        $biliId=[guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO online_searches(id,query,source,state,created_at,expires_at) VALUES(@id,'湖面','bilibili','DONE',@now,@now);" -Params @{id=$biliId;now=(Get-NowIso)} | Out-Null
        (Start-OnlineMusicSearch -Config $fixture.Config -Query '湖面' -Source bilibili).Body.id | Should Be $biliId
        (Start-OnlineMusicSearch -Config $fixture.Config -Query '湖面' -Source netease).Body.id | Should Be $searchId
        (Get-OnlineMusicSearch -SearchId $biliId).source | Should Be bilibili
    }
    It 'upgrades old search rows idempotently and labels them NetEase' {
        Invoke-MusicServerSqlNonQuery -Query 'DROP TABLE online_search_results; DROP TABLE online_searches; CREATE TABLE online_searches(id TEXT PRIMARY KEY,query TEXT,state TEXT,error_code TEXT,created_at TEXT,expires_at TEXT); INSERT INTO online_searches(id) VALUES (''legacy'');' | Out-Null
        Initialize-OnlineSearchSchema
        Initialize-OnlineSearchSchema
        (Invoke-MusicServerSqlJson -Query "SELECT source FROM online_searches WHERE id='legacy';").source | Should Be netease
    }
    It 'reads Bilibili metadata without download components and strips only search highlighting' {
        $fixture.Config.YtDlp=Join-Path $fixture.Root 'absent-ytdlp.exe'
        Mock Invoke-RestMethod -ModuleName MusicServer.Providers { '{"code":0,"data":{"result":[{"bvid":"BV1xx411c7mD","title":"<em>Song</em> &amp; Rain","duration":"03:21","author":"UP"},{"bvid":"BV1xx411c7mE","title":"Short","duration":"2:7"},{"bvid":"BV1xx411c7mF","title":"Invalid","duration":"2:99"}]}}' | ConvertFrom-Json }
        $result=Search-BilibiliCandidates -Config $fixture.Config -Track ([pscustomobject]@{title='Song';artist=''}) -Query Song
        $result.Error | Should Be ''
        @($result.Candidates).Count | Should Be 2
        $result.Candidates[0].title | Should Be 'Song & Rain'
        $result.Candidates[0].duration | Should Be 201
        $result.Candidates[1].duration | Should Be 127
        $result.Candidates[0].artist | Should Be ''
    }
    It 'reports Bilibili rate limits without retrying the blocked source' {
        $fixture.Config.YtDlp=$fixture.Config.Sqlite
        Record-ProviderFailure -Config $fixture.Config -Provider bilibili_search -HttpStatus 412 | Out-Null
        Invoke-OnlineMusicSearch -Config $fixture.Config -SearchId $searchId -Query test -Source bilibili
        (Get-OnlineMusicSearch -SearchId $searchId).error | Should Be PROVIDER_UNAVAILABLE
        (Get-ProviderHealth -Config $fixture.Config -Provider bilibili_search).failure_count | Should Be 1
    }
}
