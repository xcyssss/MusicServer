$ProjectRoot = Split-Path -Parent $PSScriptRoot

Describe 'MusicServer canonical state and queue' {
    BeforeEach {
        $TestRoot = Join-Path ([IO.Path]::GetTempPath()) "musicserver_pester_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Force
        $Config = New-MusicServerConfig -Root $TestRoot
        Initialize-MusicServerState -Config $Config
    }

    AfterEach {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps a stable canonical id when source metadata order changes' {
        $first = Get-CanonicalTrackId -Title 'Test Song' -Artist 'Artist A,Artist B'
        $second = Get-CanonicalTrackId -Title 'Test Song' -Artist 'Artist B, Artist A'
        $first | Should Be $second
        $first | Should Match '^track_[0-9a-f]{24}$'
    }

    It 'does not merge a live version into the studio track' {
        $studio = Get-CanonicalTrackId -Title 'Same Song' -Artist 'Artist'
        $live = Get-CanonicalTrackId -Title 'Same Song (Live)' -Artist 'Artist'
        $studio | Should Not Be $live
    }

    It 'preserves local identity when the same track is recommended again' {
        $first = New-CanonicalTrack -Title 'Stable Song' -Artist 'Artist' -Status 'LOCAL' -LocalSongId 'nav-123' `
            -DownloadCandidates @([pscustomobject]@{ provider = 'bilibili_direct'; bvid = 'BVknown' })
        Save-CanonicalTrack -Config $Config -Track $first | Out-Null
        $second = New-CanonicalTrack -TrackId $first.id -Title 'Stable Song' -Artist 'Artist' -Status 'REMOTE' `
            -DownloadCandidates @([pscustomobject]@{ provider = 'bilibili_search'; requires_search = $true })
        Save-CanonicalTrack -Config $Config -Track $second | Out-Null
        $stored = Get-CanonicalTrack -Config $Config -TrackId $first.id

        $stored.status | Should Be 'LOCAL'
        $stored.local_song_id | Should Be 'nav-123'
        @($stored.download_candidates).Count | Should Be 2
    }

    It 'returns like immediately and adds the track to Wanted Queue' {
        $track = New-CanonicalTrack -Title 'Queue Song' -Artist 'Artist' -Duration 200
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        $recommendation = [pscustomobject]@{
            id = 'rec_test'; date = Get-TodayDate; track_id = $track.id; title = $track.title
            artist = $track.artist; duration = $track.duration; rank = 1; liked = $false
        }
        Save-DailyRecommendations -Config $Config -Recommendations @($recommendation)

        $result = Set-TrackLike -Config $Config -TrackId $track.id -Liked $true

        $result.liked | Should Be $true
        @((Get-WantedTracks -Config $Config) | Where-Object { $_.track_id -eq $track.id }).Count | Should Be 1
        (Get-WantedTracks -Config $Config | Select-Object -First 1).state | Should Be 'WANTED'
    }

    It 'keeps repeated likes idempotent' {
        $track = New-CanonicalTrack -Title 'Idempotent Song' -Artist 'Artist'
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        Save-DailyRecommendations -Config $Config -Recommendations @([pscustomobject]@{ id = 'rec_idempotent'; date = Get-TodayDate; track_id = $track.id; title = $track.title; artist = $track.artist; liked = $false })
        Set-TrackLike -Config $Config -TrackId $track.id -Liked $true | Out-Null
        Set-TrackLike -Config $Config -TrackId $track.id -Liked $true | Out-Null
        @((Get-WantedTracks -Config $Config) | Where-Object track_id -eq $track.id).Count | Should Be 1
    }

    It 'selects a local match without asking a remote provider' {
        New-Item -ItemType File -Path (Join-Path $Config.MusicDir 'Local Song - Artist.mp3') -Force | Out-Null
        $track = New-CanonicalTrack -Title 'Local Song' -Artist 'Artist' -Duration 200
        $ranked = @(Resolve-DownloadCandidates -Config $Config -Track $track)

        $ranked.Count | Should Be 1
        $ranked[0].Candidate.provider | Should Be 'local'
        (Get-ProviderHealth -Config $Config -Provider 'bilibili').success_count | Should Be 0
    }

    It 'does not treat a same-artist different-title file as a local match' {
        New-Item -ItemType File -Path (Join-Path $Config.MusicDir 'EXO-K《mama》百万豪装录音棚大声听.mp3') -Force | Out-Null
        $match = Find-LocalTrack -Config $Config -Title 'Lucky' -Artist 'EXO-K'

        ($null -eq $match) | Should Be $true
    }

    It 'does not treat a one-character title inside another filename as a local match' {
        New-Item -ItemType File -Path (Join-Path $Config.MusicDir '【中字⧸沪萝】ykls金婚曲，你俩把日子过好比什么都重要.mp3') -Force | Out-Null
        $match = Find-LocalTrack -Config $Config -Title '过' -Artist '王嘉尔,林俊杰'

        ($null -eq $match) | Should Be $true
    }

    It 'does not treat a same-title different-artist file as a local match' {
        New-Item -ItemType File -Path (Join-Path $Config.MusicDir '《明日方舟》EP - Follow Your Heart.mp3') -Force | Out-Null
        $match = Find-LocalTrack -Config $Config -Title 'Follow Your Heart' -Artist '塞壬唱片-MSR,真名辺あや,TMKJ'

        ($null -eq $match) | Should Be $true
    }

    It 'rejects a clearly wrong duration before download' {
        $track = New-CanonicalTrack -Title 'Duration Song' -Artist 'Artist' -Duration 200 `
            -DownloadCandidates @([pscustomobject]@{ provider = 'bilibili_direct'; bvid = 'BVwrong'; duration = 400; priority = 70 })
        $ranked = @(Resolve-DownloadCandidates -Config $Config -Track $track)

        $ranked.Count | Should Be 0
    }

    It 'opens Bilibili circuit on 412 and prevents later requests' {
        $health = Record-ProviderFailure -Config $Config -Provider 'bilibili' -HttpStatus 412
        $track = New-CanonicalTrack -Title 'Blocked Song' -Artist 'Artist' -Duration 200 `
            -DownloadCandidates @([pscustomobject]@{ provider = 'bilibili_direct'; bvid = 'BVblocked'; duration = 200; priority = 70 })
        $ranked = @(Resolve-DownloadCandidates -Config $Config -Track $track)

        $health.state | Should Be 'OPEN'
        $ranked.Count | Should Be 0
    }

    It 'allows exactly one half-open probe and closes after success' {
        $health = Record-ProviderFailure -Config $Config -Provider 'bilibili' -HttpStatus 412
        $health.blocked_until = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        Save-ProviderHealth -Config $Config -Health $health | Out-Null

        (Claim-ProviderRequest -Config $Config -Provider 'bilibili') | Should Be $true
        (Claim-ProviderRequest -Config $Config -Provider 'bilibili') | Should Be $false
        Record-ProviderSuccess -Config $Config -Provider 'bilibili' | Out-Null
        (Get-ProviderHealth -Config $Config -Provider 'bilibili').state | Should Be 'CLOSED'
        (Claim-ProviderRequest -Config $Config -Provider 'bilibili') | Should Be $true
    }

    It 'keeps daily recommendation source free of download calls' {
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_recommend.ps1') -Raw
        ($source -match '&\s+\$YtDlp|Invoke-BilibiliDownload|bilisearch10') | Should Be $false
    }
}
