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
}
