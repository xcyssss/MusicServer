<##
.SYNOPSIS
    每日音乐推荐：只生成远程推荐和试听元数据，不下载音频。
.DESCRIPTION
    推荐运行时只从 SQLite 读取/写入 recommendation state。首次非 DryRun
    执行可以通过 migration marker 导入 legacy JSON/CSV；marker 写入后，
    legacy 文件不再参与 seed、cooldown 或 recommendation 决策。
    Navidrome starred 仍是外部动态偏好；本阶段不把 Navidrome DB 改成
    MusicServer 的状态源。
.PARAMETER Count
    目标推荐数量，默认 20。
.PARAMETER DryRun
    只打印推荐，不写 recommendation state，也不触发 migration。
.PARAMETER MigrateLegacy
    显式执行一次 legacy JSON/CSV 到 SQLite 的迁移；默认不自动激活生产迁移。
.PARAMETER SeedCount
    使用的种子数量，默认 25。
.PARAMETER LocalCount
    从本地库重听推荐的曲目数量上限，默认 6；设为 0 可关闭本地来源。
.PARAMETER Root
    项目根目录；默认当前脚本所在目录，主要用于测试和迁移。
.PARAMETER AppHome
    运行时/数据主目录；默认按环境变量或平台默认解析，计划任务用它锁定目标。
.PARAMETER RandomSeed
    可选测试随机种子；默认使用正常随机行为。
##>
param(
    [int]$Count = 20,
    [switch]$DryRun,
    [int]$SeedCount = 25,
    [int]$LocalCount = 6,
    [string]$Root = $PSScriptRoot,
    [string]$AppHome = '',
    [int]$RandomSeed = -1,
    [switch]$MigrateLegacy
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Migration.psm1') -Force

$Config = New-MusicServerConfig -Root $Root -AppHome $AppHome
$dbPath = Join-Path $Config.StateDir 'musicserver.db'
if ($DryRun) {
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        throw "DryRun requires an existing SQLite database: $dbPath"
    }
    Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
} else {
    Initialize-MusicServerState -Config $Config -SkipLibrary
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
    Initialize-MusicServerSchema
}
Apply-ConfiguredMusicDir -Config $Config
if (-not $DryRun) { Initialize-MusicServerLibrary -Config $Config | Out-Null }
# Legacy import is an explicit activation step. DryRun never opens the
# JSON/CSV migration input path, and a normal scheduled run cannot silently
# activate production migration by itself.
if ($MigrateLegacy -and -not $DryRun) {
    $migration = Invoke-MusicServerMigration -Config $Config
    if ([string]$migration.status -eq 'FAILED') { throw "Recommendation state migration failed: $($migration.error)" }
}

$Headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
    'Referer'    = 'https://music.163.com/'
}
$RecommendationCooldownDays = 14
# How hard a disliked song is pushed down. A fresh candidate scores 1 per seed
# that surfaced it (typically 1-3), so -5 reliably sinks a disliked track below
# anything else while still leaving it reachable when the pool is thin.
$DislikeScorePenalty = 5
$DislikeWeightDivisor = 4

function Write-Step([string]$Message) { Write-Host "`n>>> $Message" -ForegroundColor Cyan }

function Search-Netease {
    param([string]$Keyword, [int]$Limit = 3)
    $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($Keyword))&type=1&limit=$Limit"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 20
        if ($response.result -and $response.result.songs) { return @($response.result.songs) }
    } catch {
        Write-Host "  网易云搜索失败：$($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    return @()
}

function Get-SimiSongs {
    param([long]$SongId, [int]$Limit = 10)
    $url = "https://music.163.com/api/v1/discovery/simiSong?songid=$SongId&limit=$Limit"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 20
        if ($response.songs) { return @($response.songs) }
    } catch {
        Write-Host "  相似歌曲请求失败：$($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    return @()
}

function Get-StarredTitles {
    if (-not (Test-Path -LiteralPath $Config.NdDb)) { return @() }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "musicserver_seed_$([guid]::NewGuid().ToString('N')).db"
    try {
        Copy-Item -LiteralPath $Config.NdDb -Destination $tmp -Force
        foreach ($ext in @('-wal','-shm')) {
            $sidecar = "$($Config.NdDb)$ext"
            if (Test-Path -LiteralPath $sidecar) { Copy-Item -LiteralPath $sidecar -Destination "$tmp$ext" -Force -ErrorAction SilentlyContinue }
        }
        $query = "select mf.title || ' - ' || coalesce(mf.artist,'') from annotation a join media_file mf on mf.id=a.item_id where a.item_type='media_file' and a.starred=1;"
        return @(& $Config.Sqlite $tmp $query 2>$null | Where-Object { $_ })
    } catch { return @() }
    finally { Remove-Item -LiteralPath "$tmp*" -Force -ErrorAction SilentlyContinue }
}

function Get-SeedPool {
    param([AllowEmptyCollection()][object[]]$LibraryFallback = @())
    $starred = @(Get-StarredTitles)
    return @(Get-RecommendationSeedCandidatesDb -SeedCount $SeedCount -NavidromeStars $starred -LibraryFallback $LibraryFallback -RandomSeed $RandomSeed)
}

# The local library, as structured rows rather than bare titles. Every downstream
# use needs more than the title: seeding wants the resolved singer beside the song
# name, and the local recommendation source needs the file and its library id to
# play the track it recommends.
#
# This deliberately does NOT filter on Navidrome's `missing` column. That column is
# only refreshed by a Navidrome scan and the packaged runtime never runs Navidrome,
# so every row stays flagged missing and the filter silently returned nothing,
# degrading every seed to a bare ".mp3" basename with no artist at all. File
# existence is the fact that matters.
function Get-LocalLibraryRows {
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    $resolvedArtists = @{}
    try { $resolvedArtists = Get-LocalTrackArtistMapDb } catch { $resolvedArtists = @{} }

    $add = {
        param([string]$Title, [string]$Artist, [string]$File, [string]$LibraryId, [bool]$ArtistIsResolved)
        if ([string]::IsNullOrWhiteSpace($Title)) { return }
        $key = if ($File) { [string](Get-MusicServerPathKey -Path $File) } else { '' }
        if ($key) {
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true
        }
        [void]$rows.Add([pscustomobject]@{
            Title = $Title; Artist = $Artist; File = $File; LibraryId = $LibraryId
            ArtistIsResolved = $ArtistIsResolved
        })
    }

    if (Test-Path -LiteralPath $Config.NdDb -PathType Leaf) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "musicserver_seedlib_$([guid]::NewGuid().ToString('N')).db"
        try {
            Copy-Item -LiteralPath $Config.NdDb -Destination $tmp -Force
            foreach ($ext in @('-wal','-shm')) {
                $sidecar = "$($Config.NdDb)$ext"
                if (Test-Path -LiteralPath $sidecar) { Copy-Item -LiteralPath $sidecar -Destination "$tmp$ext" -Force -ErrorAction SilentlyContinue }
            }
            $query = "select id || char(9) || title || char(9) || coalesce(path,'') from media_file where title is not null and title <> '';"
            foreach ($line in @(& $Config.Sqlite $tmp $query 2>$null)) {
                $parts = [string]$line -split "`t"
                if ($parts.Count -lt 3) { continue }
                $file = [string]$parts[2]
                if ($file -and -not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $Config.MusicDir $file }
                if ($file -and -not [IO.File]::Exists($file)) { continue }
                if ($file -and (Test-Path -LiteralPath $Config.DailyDir -PathType Container)) {
                    # DailyMix holds previously downloaded recommendations, not the
                    # user's own collection; seeding from it would recommend the
                    # recommender's own output back to them.
                    $dailyFull = [IO.Path]::GetFullPath($Config.DailyDir).TrimEnd('\')
                    if ([IO.Path]::GetFullPath($file).StartsWith($dailyFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
                }
                $artist = ''
                $isResolved = $false
                if ($file) {
                    $row = $resolvedArtists[[string](Get-MusicServerPathKey -Path $file)]
                    if ($row -and [string]$row.artist -and [string]$row.status -eq 'RESOLVED') {
                        $artist = [string]$row.artist
                        $isResolved = $true
                    }
                }
                & $add ([string]$parts[1]) $artist $file ('library-' + [string]$parts[0]) $isResolved
            }
        } catch { }
        finally { Remove-Item -LiteralPath "$tmp*" -Force -ErrorAction SilentlyContinue }
    }

    foreach ($entry in @(Get-ChildItem -LiteralPath $Config.MusicDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a' })) {
        $file = [IO.Path]::GetFullPath($entry.FullName)
        if (Test-Path -LiteralPath $Config.DailyDir -PathType Container) {
            $dailyFull = [IO.Path]::GetFullPath($Config.DailyDir).TrimEnd('\')
            if ($file.StartsWith($dailyFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        $artist = ''
        $isResolved = $false
        $row = $resolvedArtists[[string](Get-MusicServerPathKey -Path $file)]
        if ($row -and [string]$row.artist -and [string]$row.status -eq 'RESOLVED') {
            $artist = [string]$row.artist
            $isResolved = $true
        }
        & $add $entry.BaseName $artist $file '' $isResolved
    }

    return @($rows)
}

Write-Step '收集本地库与种子歌曲'
$localRows = @(Get-LocalLibraryRows)
Write-Host "  本地库曲目：$($localRows.Count)（其中已解析歌手 $(@($localRows | Where-Object { $_.ArtistIsResolved }).Count) 首）" -ForegroundColor Yellow

$picked = @(Get-SeedPool)
if ($picked.Count -eq 0) {
    # A fresh install has no likes, no stars and no legacy import, so the
    # preference-only pool is empty and the day would silently save zero
    # recommendations. The local library is the weakest signal and is only
    # consulted here, so it cannot dilute a pool that reflects real taste.
    if ($localRows.Count -gt 0) {
        Write-Host "  未发现偏好种子，改用本地库种子：$($localRows.Count)" -ForegroundColor Yellow
        $picked = @(Get-SeedPool -LibraryFallback $localRows)
    }
}
Write-Host "  本次选用种子：$($picked.Count)" -ForegroundColor Yellow
foreach ($seed in $picked) { Write-Host "    - $($seed.Title) - $($seed.Artist) [$($seed.Source), weight=$($seed.Weight)]" -ForegroundColor DarkGray }

Write-Step '建立 SQLite 排除集与近期推荐冷却'
$exclude = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in @(Get-ChildItem -LiteralPath $Config.MusicDir -Filter '*.mp3' -File -Recurse -ErrorAction SilentlyContinue)) {
    [void]$exclude.Add((Normalize-MusicText $file.BaseName))
}
foreach ($row in @(Get-RecommendationExcludedKeysDb)) {
    if ($row.Title) { [void]$exclude.Add((Normalize-MusicText $row.Title)) }
    if ($row.NeteaseId) { [void]$exclude.Add("netease:$($row.NeteaseId)") }
    if ($row.TrackId) { [void]$exclude.Add("track:$($row.TrackId)") }
}
$acceptedIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in @(Get-RecommendationExcludedKeysDb | Where-Object { [string]$_.FeedbackType -eq 'ACCEPTED' })) {
    if ($row.NeteaseId) { [void]$acceptedIds.Add([string]$row.NeteaseId) }
}

$today = Get-TodayDate
$cooldownRows = @(Get-RecommendationCooldownTrackIdsDb -AsOfDate $today -CooldownDays $RecommendationCooldownDays)
$cooldownCount = 0
foreach ($row in $cooldownRows) {
    if ($row.netease_id -and $exclude.Add("netease:$($row.netease_id)")) { $cooldownCount++ }
    if ($row.track_id) { [void]$exclude.Add("track:$($row.track_id)") }
}
Write-Host "  排除条目：$($exclude.Count)，已接受网易云 ID：$($acceptedIds.Count)，近期冷却：$cooldownCount" -ForegroundColor Yellow

# Disliked tracks, resolved once and used by BOTH sources below. "少推荐" is a soft
# penalty, not an exclusion: the track keeps a much lower weight, so it sinks below
# fresh candidates but can still surface when there is nothing better. Excluding it
# outright, the way REJECTED does, would not be what was asked for.
$dislikedKeys = Get-DislikePenaltyKeys -Disliked @(Get-DislikedTrackKeysDb)
if ($dislikedKeys.Count -gt 0) { Write-Host "  讨厌歌曲键：$($dislikedKeys.Count)" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Local re-listen recommendations
#
# NetEase answers "what should I discover". This answers the opposite question:
# which of the tracks already in the library does this listener most likely want
# to hear again. It is preference-led, not library-led -- a track is only eligible
# when the listener has already shown interest in that artist -- so a large
# untouched library cannot turn the day into an arbitrary dump of its own files.
#
# The library-wide exclude set above is deliberately NOT used here: it contains
# every owned file's basename, which is exactly inverted for this source. Only
# things already recommended, accepted or rejected are excluded.
# ---------------------------------------------------------------------------
Write-Step '生成本地库重听推荐'
$listeningRows = @()
try { $listeningRows = @(Get-ListeningStatsDb) } catch { $listeningRows = @() }

$lastPlayedByLibrary = @{}
foreach ($row in $listeningRows) {
    $libId = [string]$row.library_id
    if (-not $libId) { continue }
    $when = [string]$row.last_played_at
    if ($when -and (-not $lastPlayedByLibrary.ContainsKey($libId) -or $when -gt [string]$lastPlayedByLibrary[$libId])) {
        $lastPlayedByLibrary[$libId] = $when
    }
}

# Only tracks with a resolved singer are eligible: clustering needs an artist, and
# the indexed value is the uploader. Guessing here would recommend by channel name.
$localCandidates = New-Object System.Collections.ArrayList
foreach ($row in $localRows) {
    if (-not $row.Artist) { continue }
    [void]$localCandidates.Add([pscustomobject]@{
        Title = [string]$row.Title; Artist = [string]$row.Artist; File = [string]$row.File
        LibraryId = [string]$row.LibraryId
        LastPlayedAt = if ($row.LibraryId -and $lastPlayedByLibrary.ContainsKey([string]$row.LibraryId)) { [string]$lastPlayedByLibrary[[string]$row.LibraryId] } else { '' }
    })
}

$localByLibrary = @{}
foreach ($candidate in $localCandidates) {
    if ($candidate.LibraryId) { $localByLibrary[[string]$candidate.LibraryId] = $candidate }
}
$affinityStats = New-Object System.Collections.ArrayList
foreach ($row in $listeningRows) {
    $plays = [int]$row.play_count
    if ($plays -le 0) { continue }
    $libId = [string]$row.library_id
    if (-not $libId -or -not $localByLibrary.ContainsKey($libId)) { continue }
    $artist = [string]$localByLibrary[$libId].Artist
    if ($artist) { [void]$affinityStats.Add([pscustomobject]@{ artist = $artist; play_count = $plays }) }
}
$affinityPositive = New-Object System.Collections.ArrayList
foreach ($row in @(Get-RecommendationExcludedKeysDb | Where-Object { [string]$_.FeedbackType -eq 'ACCEPTED' })) {
    $canonical = $null
    if ($row.TrackId) { try { $canonical = Get-CanonicalTrackDb -TrackId ([string]$row.TrackId) } catch { $canonical = $null } }
    if ($canonical -and [string]$canonical.artist) { [void]$affinityPositive.Add([pscustomobject]@{ Artist = [string]$canonical.artist }) }
}
$affinity = Get-LocalArtistAffinity -ListeningStats $affinityStats -PositiveTracks $affinityPositive

$localExclude = New-Object System.Collections.ArrayList
foreach ($row in @(Get-RecommendationExcludedKeysDb)) {
    if ($row.Title) { [void]$localExclude.Add([string]$row.Title) }
    if ($row.TrackId) { [void]$localExclude.Add([string]$row.TrackId) }
}
foreach ($row in $cooldownRows) { if ($row.track_id) { [void]$localExclude.Add([string]$row.track_id) } }
try {
    foreach ($row in @(Get-TodayRecommendationsDb -Date $today)) {
        if ($row.title) { [void]$localExclude.Add([string]$row.title) }
        if ($row.track_id) { [void]$localExclude.Add([string]$row.track_id) }
    }
} catch { }

$localBudget = [Math]::Max(0, [Math]::Min($LocalCount, $Count))
$localPicks = @()
if ($localBudget -gt 0 -and $affinity.Count -gt 0) {
    # The dislike penalty is applied inside the selection so a disliked owned track
    # loses its slot to a non-disliked one; demoting afterwards would only reorder
    # the picks already chosen.
    $localPicks = @(Select-LocalRecommendationTracks -Candidates @($localCandidates) -Affinity $affinity -ExcludedKeys @($localExclude) -Limit $localBudget -DislikeKeys $dislikedKeys -DislikeWeightDivisor $DislikeWeightDivisor)
}
Write-Host "  本地重听推荐：$($localPicks.Count) 首（候选 $($localCandidates.Count) 首，歌手亲和度 $($affinity.Count) 个，预算 $localBudget）" -ForegroundColor Yellow

Write-Step '从网易云生成相似歌曲 metadata'
$candidateMap = @{}
$seedMisses = 0
foreach ($seed in $picked) {
    # Searching the raw uploader title wastes the seed: it is the song name plus
    # channel branding plus the song name again. Each cleaned form is tried with
    # the resolved singer first and alone second, and the search only accepts a
    # candidate whose title matches the query, so a wrong artist cannot be picked.
    $found = @()
    foreach ($query in @(Get-SongSearchQueries -Title ([string]$seed.Title) -Artist ([string]$seed.Artist))) {
        $hits = @(Search-Netease -Keyword $query -Limit 3)
        if ($hits.Count -eq 0) { continue }
        $wantKey = ConvertTo-MusicServerKey -Value $query
        foreach ($hit in $hits) {
            $gotKey = ConvertTo-MusicServerKey -Value ([string]$hit.name)
            if ($gotKey.Length -ge 2 -and ($gotKey -eq $wantKey -or $wantKey.Contains($gotKey) -or $gotKey.Contains($wantKey))) {
                $found = @($hit); break
            }
        }
        if ($found.Count -gt 0) { break }
    }
    if ($found.Count -eq 0) { $seedMisses++; continue }
    $similar = @(Get-SimiSongs -SongId ([long]$found[0].id) -Limit 10)
    foreach ($song in $similar) {
        $sid = [string]$song.id
        $artist = (($song.artists | ForEach-Object { $_.name }) -join ',')
        $candidateTrackId = ''
        if ($song.name -and $artist) { $candidateTrackId = Get-CanonicalTrackId -Title ([string]$song.name) -Artist $artist }
        if (-not $sid -or $acceptedIds.Contains($sid) -or $exclude.Contains("netease:$sid") -or ($candidateTrackId -and $exclude.Contains("track:$candidateTrackId"))) { continue }
        if ($candidateMap.ContainsKey($sid)) { $candidateMap[$sid].Score++; continue }
        $duration = [int]($song.duration / 1000)
        if ($duration -lt 60 -or $duration -gt 600) { continue }
        if ($song.name -match '合集|串烧|伴奏|instrumental|纯音乐|Cover |cover版|铃声|remix版|片段|试听|DJ版|女声版|男声版|慢搖|抖音版|加速版|减速版|清唱') { continue }
        if ($artist -match 'Cover|翻唱') { continue }
        $key = Normalize-MusicText "$($song.name)$artist"
        if ($exclude.Contains($key) -or $exclude.Contains((Normalize-MusicText $song.name))) { continue }
        $candidateMap[$sid] = [pscustomobject]@{
            NeteaseId = $sid; Title = [string]$song.name; Artist = $artist; Album = [string]$song.album.name
            Duration = $duration; FromSeed = [string]$seed.Title; SeedSource = [string]$seed.Source; Score = 1; CoverUrl = [string]$song.album.picUrl
            ReleaseYear = Get-NeteasePublishYear -PublishTime (Get-OptionalProperty (Get-OptionalProperty $song 'album' $null) 'publishTime' 0)
        }
    }
}

# Disliked tracks are pushed down rather than removed. "少推荐" is a soft penalty:
# a disliked song keeps a much lower score than a fresh candidate, so it sinks out
# of the day under normal circumstances but can still appear when there is nothing
# better -- which is what excluding it outright would prevent.
$dislikePenalty = 0
if ($dislikedKeys.Count -gt 0) {
    foreach ($candidate in @($candidateMap.Values)) {
        $isDisliked = Test-CandidateDisliked -Title ([string]$candidate.Title) -Artist ([string]$candidate.Artist) `
            -NeteaseId ([string]$candidate.NeteaseId) -PenaltyKeys $dislikedKeys
        if ($isDisliked) { $candidate.Score = $candidate.Score - $DislikeScorePenalty; $dislikePenalty++ }
    }
    Write-Host "  讨厌歌曲命中：$dislikePenalty 首（每首 -$DislikeScorePenalty 分）" -ForegroundColor Yellow
}

$ranked = @($candidateMap.Values | Sort-Object @{Expression = {$_.Score}; Descending = $true}, @{Expression = { Get-Random }})
$recos = @(); $artists = @{}
foreach ($candidate in $ranked) {
    $artistKey = Normalize-MusicText (($candidate.Artist -split '[,，、]')[0])
    if ($artistKey -and $artists.ContainsKey($artistKey) -and $artists[$artistKey] -ge 5) { continue }
    $recos += $candidate
    if ($artistKey) { if ($artists.ContainsKey($artistKey)) { $artists[$artistKey]++ } else { $artists[$artistKey] = 1 } }
    if ($recos.Count -ge ($Count - @($localPicks).Count)) { break }
}

$recommendations = @(); $tracks = @(); $rank = 0
foreach ($candidate in $recos) {
    $rank++
    $trackId = Get-CanonicalTrackId -Title $candidate.Title -Artist $candidate.Artist
    $preview = @([pscustomobject]@{
        provider = 'netease'; id = $candidate.NeteaseId
        url = "https://music.163.com/#/song?id=$($candidate.NeteaseId)"
        media_url = "https://music.163.com/song/media/outer/url?id=$($candidate.NeteaseId).mp3"
        duration = $candidate.Duration
    })
    $identifiers = @([pscustomobject]@{ type = 'netease'; value = $candidate.NeteaseId })
    $downloadCandidates = @(
        [pscustomobject]@{ provider = 'local'; priority = 100; requires_search = $false }
        [pscustomobject]@{ provider = 'bilibili_direct'; priority = 70; requires_search = $false }
        [pscustomobject]@{ provider = 'bilibili_search'; priority = 10; requires_search = $true }
    )
    $track = New-CanonicalTrack -TrackId $trackId -Title $candidate.Title -Artist $candidate.Artist -Album $candidate.Album `
        -Duration $candidate.Duration -CoverUrl $candidate.CoverUrl -Identifiers $identifiers `
        -PreviewSources $preview -DownloadCandidates $downloadCandidates -Status 'REMOTE' `
        -ReleaseYear ([int](Get-OptionalProperty $candidate 'ReleaseYear' 0))
    $tracks += $track
    $recommendations += [pscustomobject]@{
        id = "rec_${today}_${rank}_$($trackId.Substring(6, 12))"
        date = $today; track_id = $trackId; netease_id = $candidate.NeteaseId
        title = $candidate.Title; artist = $candidate.Artist; album = $candidate.Album
        duration = $candidate.Duration; rank = $rank; reason = "相似于：$($candidate.FromSeed)"
        seed_source = $candidate.SeedSource
        playback_source = "netease:$($candidate.NeteaseId)"; preview_sources = $preview
        liked = $false; created_at = Get-NowIso; updated_at = Get-NowIso
    }
}

# Append the local re-listen picks, continuing the same rank sequence so the day is
# one list rather than two. Save-DailyRecommendationsDb keys tracks by id, so a pick
# already produced by the online path is skipped instead of overwriting it.
$localAdded = 0
foreach ($pick in $localPicks) {
    $pickTrackId = ''
    try { $pickTrackId = Get-CanonicalTrackId -Title ([string]$pick.Title) -Artist ([string]$pick.Artist) } catch { $pickTrackId = '' }
    if (-not $pickTrackId) { continue }
    if (@($tracks | Where-Object { [string]$_.id -eq $pickTrackId }).Count -gt 0) { continue }
    $rank++
    $identifiers = @()
    if ($pick.LibraryId) { $identifiers = @([pscustomobject]@{ type = 'local'; value = [string]$pick.LibraryId }) }
    $tracks += New-CanonicalTrack -TrackId $pickTrackId -Title ([string]$pick.Title) -Artist ([string]$pick.Artist) -Album '' `
        -Duration 0 -CoverUrl '' -Identifiers $identifiers -PreviewSources @() -DownloadCandidates @() `
        -LocalSongId ([string]$pick.LibraryId) -Status 'LOCAL'
    $recommendations += [pscustomobject]@{
        id = "rec_${today}_${rank}_$($pickTrackId.Substring(6, 12))"
        date = $today; track_id = $pickTrackId; netease_id = ''
        title = [string]$pick.Title; artist = [string]$pick.Artist; album = ''
        duration = 0; rank = $rank; reason = "重听：$($pick.AffinityArtist)"
        seed_source = 'local_library'
        playback_source = "local:$($pick.LibraryId)"; preview_sources = @()
        liked = $false; created_at = Get-NowIso; updated_at = Get-NowIso
    }
    $localAdded++
}
if ($localAdded -gt 0) { Write-Host "  已加入本地重听推荐：$localAdded 首" -ForegroundColor Green }

Write-Host "`n候选推荐：$($candidateMap.Count) 首，取前 $($recommendations.Count) 首" -ForegroundColor Green
foreach ($r in $recommendations) {
    Write-Host ("  {0,2}. {1} - {2} ({3}s) | {4} | seed={5}" -f $r.rank, $r.title, $r.artist, $r.duration, $r.playback_source, $r.seed_source) -ForegroundColor White
}

if (-not $DryRun) {
    $saveResult = Save-DailyRecommendationsDb -Recommendations $recommendations -Tracks $tracks -Date $today
    Write-MusicServerEventDb -EventType 'RECOMMENDATIONS_GENERATED' -Result 'SUCCESS' -Message "count=$($recommendations.Count); download_calls=0; feedback=explicit_only; cooldown_days=$RecommendationCooldownDays"
    Write-Host "`n已原子保存 SQLite CanonicalTrack、DailyRecommendation 和 DISPLAY。" -ForegroundColor Green
} else {
    Write-Host "`n【DryRun 模式，未写 recommendation 状态】" -ForegroundColor Magenta
}
Write-Host '推荐阶段不会调用 yt-dlp、Bilibili 下载、ffprobe、歌词下载或 Navidrome 扫描。' -ForegroundColor Cyan
