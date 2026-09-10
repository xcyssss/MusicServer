<#
    Artist resolution tests.

    Local Bilibili downloads carry the uploader in their tags, so the real singer
    has to be resolved. These tests pin the two things that make that safe:

      1. The precision gate -- an online search result is only accepted when the
         file name itself already contains the artist it credits. Without it,
         searching by song name returns a different recording of the same song
         ("EXO-M - MAMA" for "EXO-K《mama》").
      2. Cache behavior -- a resolved row is served forever, and a recorded miss
         is not re-queried on every start.

    Nothing here performs network I/O.
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Force

function New-ArtistTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('msartist_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'DailyMix_data\state') -Force
    return $root
}

function Initialize-ArtistTestState {
    param([Parameter(Mandatory)][string]$Root)
    $config = New-MusicServerConfig -Root $ProjectRoot -AppHome $Root
    Initialize-MusicServerState -Config $config
    $dbPath = Join-Path $config.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $config.Sqlite
    Initialize-MusicServerSchema
    return $config
}

function New-NeteaseSong {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Artists,
        [int]$Seconds = 240,
        [string]$Album = 'Some Album'
    )
    return [pscustomobject]@{
        id = [Math]::Abs($Name.GetHashCode())
        name = $Name
        duration = $Seconds * 1000
        album = [pscustomobject]@{ name = $Album }
        artists = @($Artists -split ',' | ForEach-Object { [pscustomobject]@{ name = $_.Trim() } })
    }
}

Describe 'MusicServer artist resolution' {

    Context 'singer declared in the file name' {

        It 'reads the artist an uploader wrote in front of the song name' {
            Get-TitleDeclaredArtist -Title 'BEYOND《冷雨夜》百万豪装录音棚大声听' | Should Be 'BEYOND'
            Get-TitleDeclaredArtist -Title 'EXO-K《mama》百万豪装录音棚大声听' | Should Be 'EXO-K'
            Get-TitleDeclaredArtist -Title 'Tobu《life》百万豪装录音棚大声听' | Should Be 'Tobu'
            Get-TitleDeclaredArtist -Title 'Alan Walker&Sabrina Carpenter&Farruko《On My Way（《和平精英》盛夏推广曲）》百万豪装录音棚大声听' | Should Be 'Alan Walker&Sabrina Carpenter&Farruko'
        }

        It 'drops a quoted lyric sitting in front of the artist' {
            Get-TitleDeclaredArtist -Title '“回忆陪我躲在角落没露面”许嵩《梧桐灯》【4K60fps黑胶】' | Should Be '许嵩'
        }

        It 'keeps the artist side when the uploader wrote "artist - song"' {
            Get-TitleDeclaredArtist -Title '咖啡因乐队 - 时光-动漫《我叫MT 第四季》' | Should Be '咖啡因乐队'
            Get-TitleDeclaredArtist -Title '同行-《我叫MT》完美药药' | Should Be '同行'
            # No spaces around the separator: "artist-song-series《...》".
            Get-TitleDeclaredArtist -Title '小树-不安的前方-动漫《我叫MT 第三季》' | Should Be '小树'
            Get-TitleDeclaredArtist -Title '棉花囡囡-泰兰德的记忆-动漫《我叫MT 第一季》' | Should Be '棉花囡囡'
        }

        It 'reads a "song - artist" tail that the online lookup cannot resolve' {
            # Searching an artist name never returns a matching song name, so the
            # file-name gate rejects every hit and this shape has to be read here.
            Get-TitleDeclaredArtist -Title 'Tokyo - Owl City' | Should Be 'Owl City'
            Get-TitleDeclaredArtist -Title '空山新雨后 - 绾绾' | Should Be '绾绾'
            Get-TitleDeclaredArtist -Title '遗忘之海（Sea of Remnants） - Alan Walker' | Should Be 'Alan Walker'
        }

        It 'refuses a tail that is really the song, a series, or marketing text' {
            # These are the shapes where guessing the tail shows a song name as an
            # artist, which is worse than showing nothing.
            Get-TitleDeclaredArtist -Title '【李佳思】音阙诗听×李佳思 - 流浪的猫写情诗·甜到掉牙的静享版（无损音质+中文字幕）' | Should Be ''
            Get-TitleDeclaredArtist -Title '《明日方舟》EP - All by My Design' | Should Be ''
            Get-TitleDeclaredArtist -Title '【夏一可】阳光之旅 - 《我叫MT》九周年纪念' | Should Be ''
            Get-TitleDeclaredArtist -Title '美周郎(合唱版) -Liu夏 ｜ Hi-Res无损音质' | Should Be ''
        }

        It 'refuses a lyric or a sentence instead of reporting it as an artist' {
            # The bracketed block here is the song; what precedes it is a lyric.
            Get-TitleDeclaredArtist -Title '“初见她漫步溪桥下，她轻摘一朵桃花”『相思遥』兰音' | Should Be ''
            Get-TitleDeclaredArtist -Title '《可惜没如果》德国钢琴家理解了林俊杰的歌词后，在上海街头的演绎。' | Should Be ''
            Get-TitleDeclaredArtist -Title '『不可说』金铃过处, 片甲不留丨《百妖谱》主题曲翻唱' | Should Be ''
        }
        It 'returns nothing when the name declares no artist' {
            Get-TitleDeclaredArtist -Title 'Some Song Without A Label' | Should Be ''
            Get-TitleDeclaredArtist -Title '' | Should Be ''
        }
    }

    Context 'online match precision' {

        It 'accepts a candidate the file name confirms' {
            Test-FileVouchesForArtist -Artist 'Beyond' -Title 'BEYOND《冷雨夜》百万豪装录音棚大声听' | Should Be $true
            Test-FileVouchesForArtist -Artist '许嵩' -Title '“回忆陪我躲在角落没露面”《梧桐灯》许嵩 【4K60fps黑胶】' | Should Be $true
        }

        It 'rejects a different recording of the same song' {
            # The whole point: identical song name, wrong singer.
            Test-FileVouchesForArtist -Artist 'EXO-M' -Title 'EXO-K《mama》百万豪装录音棚大声听' | Should Be $false
            Test-FileVouchesForArtist -Artist 'XG' -Title 'Hearts2Hearts《RUDE!》百万豪装录音棚大声听' | Should Be $false
        }

        It 'rejects a candidate whose artists are only partly confirmed' {
            Test-FileVouchesForArtist -Artist 'Alan Walker,Nobody At All' -Title 'Alan Walker《On My Way》' | Should Be $false
        }

        It 'never accepts an empty artist' {
            Test-FileVouchesForArtist -Artist '' -Title 'Anything' | Should Be $false
        }
    }

    Context 'search response selection' {

        It 'picks the candidate the file name vouches for, not merely the first result' {
            $songs = @(
                (New-NeteaseSong -Name 'MAMA' -Artists 'EXO-M' -Seconds 270),
                (New-NeteaseSong -Name 'MAMA' -Artists 'EXO-K' -Seconds 270)
            )
            $match = Select-NeteaseArtistForTitle -Title 'EXO-K《mama》百万豪装录音棚大声听' -Keyword 'mama' -DurationSeconds 270 -Songs $songs
            $match.artist | Should Be 'EXO-K'
        }

        It 'returns nothing when no candidate is confirmed by the file name' {
            $songs = @((New-NeteaseSong -Name 'MAMA' -Artists 'EXO-M' -Seconds 270))
            $match = Select-NeteaseArtistForTitle -Title 'EXO-K《mama》百万豪装录音棚大声听' -Keyword 'mama' -DurationSeconds 270 -Songs $songs
            $match | Should BeNullOrEmpty
        }

        It 'does not gate on duration, because uploads pad or extend the song' {
            # A 25-minute single-file upload still names the right singer.
            $songs = @((New-NeteaseSong -Name 'ZEAL of proud' -Artists 'Roselia' -Seconds 279))
            $match = Select-NeteaseArtistForTitle -Title 'ZEAL of proud - Roselia' -Keyword 'ZEAL of proud' -DurationSeconds 1540 -Songs $songs
            $match.artist | Should Be 'Roselia'
        }

        It 'keeps the closest duration only as a tie-breaker' {
            $songs = @(
                (New-NeteaseSong -Name '冷雨夜' -Artists 'Beyond' -Seconds 300),
                (New-NeteaseSong -Name '冷雨夜' -Artists 'Beyond' -Seconds 261)
            )
            $match = Select-NeteaseArtistForTitle -Title 'BEYOND《冷雨夜》百万豪装录音棚大声听' -Keyword '冷雨夜' -DurationSeconds 262 -Songs $songs
            $match.artist | Should Be 'Beyond'
        }

        It 'carries the album name when the response provides one' {
            $songs = @((New-NeteaseSong -Name 'life' -Artists 'Tobu' -Seconds 204 -Album 'NCS'))
            $match = Select-NeteaseArtistForTitle -Title 'Tobu《life》百万豪装录音棚大声听' -Keyword 'life' -DurationSeconds 203 -Songs $songs
            $match.album | Should Be 'NCS'
        }
    }

    Context 'search keywords' {

        It 'tries the bracketed song name as well as the cleaned title' {
            $keywords = @(Get-TitleSearchKeywords -Title '【附歌词中字】Roselia「Dazzle the Destiny」【FULL】')
            ($keywords -contains 'Dazzle the Destiny') | Should Be $true
        }

        It 'never returns more than the three most precise keywords' {
            $keywords = @(Get-TitleSearchKeywords -Title '【单曲纯享】张杰《星星》')
            $keywords.Count | Should BeLessThan 4
            $keywords.Count | Should BeGreaterThan 0
        }

        It 'returns nothing usable for a title with no song-like content' {
            @(Get-TitleSearchKeywords -Title '').Count | Should Be 0
        }
    }

    Context 'resolved artist cache' {

        It 'round-trips a resolved artist by normalized path' {
            $root = New-ArtistTestRoot
            try {
                $null = Initialize-ArtistTestState -Root $root
                $key = Get-MusicServerPathKey -Path (Join-Path $root 'Music\Song.mp3')
                Save-LocalTrackArtistDb -PathKey $key -Artist '许嵩' -Album '自定义' -Status 'RESOLVED' -Source 'netease' | Out-Null

                $map = Get-LocalTrackArtistMapDb
                $map.ContainsKey($key) | Should Be $true
                $map[$key].artist | Should Be '许嵩'
                $map[$key].status | Should Be 'RESOLVED'
                $map[$key].source | Should Be 'netease'

                $row = Get-LocalTrackArtistDb -PathKey $key
                $row.artist | Should Be '许嵩'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'records a miss so the same lookup is not repeated' {
            $root = New-ArtistTestRoot
            try {
                $null = Initialize-ArtistTestState -Root $root
                $key = Get-MusicServerPathKey -Path (Join-Path $root 'Music\Unknown.mp3')
                Save-LocalTrackArtistDb -PathKey $key -Status 'NOT_FOUND' -Source 'none' | Out-Null

                $row = Get-LocalTrackArtistDb -PathKey $key
                $row.status | Should Be 'NOT_FOUND'
                $row.artist | Should Be ''
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'replaces an earlier miss once a resolution succeeds' {
            $root = New-ArtistTestRoot
            try {
                $null = Initialize-ArtistTestState -Root $root
                $key = Get-MusicServerPathKey -Path (Join-Path $root 'Music\Later.mp3')
                Save-LocalTrackArtistDb -PathKey $key -Status 'NOT_FOUND' -Source 'none' | Out-Null
                Save-LocalTrackArtistDb -PathKey $key -Artist 'Roselia' -Status 'RESOLVED' -Source 'title' | Out-Null

                $row = Get-LocalTrackArtistDb -PathKey $key
                $row.artist | Should Be 'Roselia'
                $row.status | Should Be 'RESOLVED'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'keys paths case-insensitively, as Windows does' {
            (Get-MusicServerPathKey -Path 'C:\Music\Song.mp3') | Should Be (Get-MusicServerPathKey -Path 'c:\music\SONG.MP3')
        }
    }

    Context 'network safety' {

        It 'performs no lookup when NetEase search is disabled' {
            $env:MUSICSERVER_DISABLE_NETEASE_SEARCH = '1'
            try {
                $root = New-ArtistTestRoot
                try {
                    $config = New-MusicServerConfig -Root $ProjectRoot -AppHome $root
                    # No state DB exists and no request may be made: a lookup here
                    # would either throw or reach the network.
                    Resolve-NeteaseTrackArtist -Config $config -Title 'BEYOND《冷雨夜》' -DurationSeconds 262 | Should BeNullOrEmpty
                } finally {
                    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                }
            } finally {
                Remove-Item Env:\MUSICSERVER_DISABLE_NETEASE_SEARCH -ErrorAction SilentlyContinue
            }
        }

        It 'leaves the provider circuit alone when disabled' {
            $root = New-ArtistTestRoot
            try {
                $config = Initialize-ArtistTestState -Root $root
                $env:MUSICSERVER_DISABLE_NETEASE_SEARCH = '1'
                try {
                    $before = Get-ProviderHealth -Config $config -Provider 'netease'
                    Resolve-NeteaseTrackArtist -Config $config -Title 'Tobu《life》' -DurationSeconds 203 | Should BeNullOrEmpty
                    $after = Get-ProviderHealth -Config $config -Provider 'netease'
                    [int]$after.success_count | Should Be ([int]$before.success_count)
                    [int]$after.failure_count | Should Be ([int]$before.failure_count)
                } finally {
                    Remove-Item Env:\MUSICSERVER_DISABLE_NETEASE_SEARCH -ErrorAction SilentlyContinue
                }
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
