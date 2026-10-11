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
    从本地库重听推荐的曲目数量上限，默认 0：每日推荐只包含远程发现，不混入已拥有的歌曲。
    传正数才启用本地重听来源。
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
    [int]$LocalCount = 0,
    [string]$Root = $PSScriptRoot,
    [string]$AppHome = '',
    [int]$RandomSeed = -1,
    [switch]$MigrateLegacy
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Migration.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Onboarding.psm1') -DisableNameChecking -Force
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'MusicServer.Library.psm1')) {
    Import-Module (Join-Path $PSScriptRoot 'MusicServer.Library.psm1') -DisableNameChecking -Force
}

$Config = New-MusicServerConfig -Root $Root -AppHome $AppHome
$recommendationMutexName = 'Local\MusicServer_Daily_' + (Get-CanonicalTrackId -Title (Get-MusicServerPathKey -Path $Config.AppHome) -Artist 'generator')
$RecommendationMutex = [Threading.Mutex]::new($false, $recommendationMutexName)
$OwnsRecommendationMutex = $false
try { $OwnsRecommendationMutex = $RecommendationMutex.WaitOne(30000) }
catch [Threading.AbandonedMutexException] { $OwnsRecommendationMutex = $true }
if (-not $OwnsRecommendationMutex) {
    Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[generation] skipped=generator_busy wait_ms=30000'
    $RecommendationMutex.Dispose()
    return
}
try {
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
$RecommendationLibraryRevision = [string](Get-AppSettingDb -Key 'recommendation_library_pending')
$RecommendationMusicDir = Get-MusicServerPathKey -Path $Config.MusicDir
if ($RecommendationLibraryRevision) {
    try { $libraryRevisionInfo = $RecommendationLibraryRevision | ConvertFrom-Json -ErrorAction Stop } catch { $libraryRevisionInfo = $null }
    if (-not $libraryRevisionInfo -or [string](Get-OptionalProperty $libraryRevisionInfo 'path_key' '') -ne $RecommendationMusicDir) {
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[generation] skipped=library_revision_scope_changed preserved_existing_day=true'
        return
    }
}
# Legacy import is an explicit activation step. DryRun never opens the
# JSON/CSV migration input path, and a normal scheduled run cannot silently
# activate production migration by itself.
if ($MigrateLegacy -and -not $DryRun) {
    $migration = Invoke-MusicServerMigration -Config $Config
    if ([string]$migration.status -eq 'FAILED') { throw "Recommendation state migration failed: $($migration.error)" }
}

$RecommendationCooldownDays = 14
# How hard a song related to a disliked one is pushed down, by how close the
# relation is. A fresh candidate scores 1 per seed that surfaced it (typically
# 1-3), so these sink a related song below unrelated ones while leaving it
# reachable when the pool is thin. "少推荐" is a penalty, never an exclusion.
$DislikeRelationPenalty = @{
    TRACK   = 5   # the disliked recording itself
    ARTIST  = 3   # another song by the same singer
    ALBUM   = 2   # another track off the same release
    SIMILAR = 2   # a song NetEase considers similar
    SEED    = 1   # discovered from the disliked song as a seed
}
# The local source ranks by affinity weight instead of a score, so the same
# relations divide that weight. SEED is 1 (no change): a local track is not
# "discovered from" anything.
$DislikeRelationDivisor = @{
    TRACK   = 4
    ARTIST  = 3
    ALBUM   = 2
    SIMILAR = 2
    SEED    = 1
}

function Write-Step([string]$Message) { Write-Host "`n>>> $Message" -ForegroundColor Cyan }

function Invoke-MusicServerDailyMetadata {
    param([psobject]$Config, [psobject]$State, [string]$Uri, [switch]$ReadOnly)
    if ($ReadOnly -or $env:MUSICSERVER_DISABLE_NETEASE_SEARCH -eq '1' -or $State.Blocked) { return $null }
    $remaining = [double]$State.BudgetSeconds - [double]$State.Clock.Elapsed.TotalSeconds
    if ($remaining -lt 1 -or [int]$State.Calls -ge 60) {
        $State.Blocked = $true; $State.StopReason = 'metadata_budget'
        return $null
    }
    if (-not (Test-ProviderRequestAvailable -Config $Config -Provider 'netease')) {
        $State.Blocked = $true; $State.StopReason = 'provider_circuit'
        return $null
    }
    if (-not (Claim-ProviderRequest -Config $Config -Provider 'netease')) {
        $State.Blocked = $true; $State.StopReason = 'provider_probe_busy'
        return $null
    }
    $State.Calls = [int]$State.Calls + 1
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers @{
            'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://music.163.com/'
        } -TimeoutSec ([int][Math]::Max(1, [Math]::Min(8, [Math]::Floor($remaining)))) -ErrorAction Stop
        $code = [int](Get-OptionalProperty $response 'code' 200)
        if ($code -ne 200 -or $response -is [string]) {
            Record-ProviderFailure -Config $Config -Provider 'netease' -HttpStatus $code -ErrorType 'DAILY_METADATA_FAILED' -Message 'Daily metadata provider rejected request.' | Out-Null
            $State.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
            if ($code -in @(412,429) -or [int]$State.ConsecutiveFailures -ge 3) {
                $State.Blocked = $true; $State.StopReason = if ($code -in @(412,429)) { "http_$code" } else { 'metadata_failures' }
            }
            return $null
        }
        Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $clock.Elapsed.TotalMilliseconds
        $State.ConsecutiveFailures = 0
        return $response
    } catch {
        $http = 0; $failedResponse = Get-OptionalProperty $_.Exception 'Response' $null
        if ($failedResponse) { $http = [int](Get-OptionalProperty $failedResponse 'StatusCode' 0) }
        Record-ProviderFailure -Config $Config -Provider 'netease' -HttpStatus $http -ErrorType 'DAILY_METADATA_FAILED' -Message 'Daily metadata transport temporarily unavailable.' | Out-Null
        $State.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
        if ($http -in @(412,429) -or [int]$State.ConsecutiveFailures -ge 3) {
            $State.Blocked = $true; $State.StopReason = if ($http -in @(412,429)) { "http_$http" } else { 'metadata_failures' }
        }
        return $null
    }
}

function Search-Netease {
    param([string]$Keyword, [int]$Limit = 3)
    $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($Keyword))&type=1&limit=$Limit"
    try {
        $response = Invoke-MusicServerDailyMetadata -Config $Config -State $DailyMetadataState -Uri $url -ReadOnly:$DryRun
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
        $response = Invoke-MusicServerDailyMetadata -Config $Config -State $DailyMetadataState -Uri $url -ReadOnly:$DryRun
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
    $resolvedArtists = @{}; $canonicalMap = @{}; $portableIndex = @{}
    try { $resolvedArtists = Get-LocalTrackArtistMapDb } catch { }
    try { $canonicalMap = Get-CanonicalLocalTrackMapDb -MusicDir $Config.MusicDir } catch { }
    if (Get-Command Get-MusicServerLibraryIndex -ErrorAction SilentlyContinue) {
        try { $portableIndex = Get-MusicServerLibraryIndex -Config $Config } catch { }
    }
    $musicRoot = [IO.Path]::GetFullPath($Config.MusicDir).TrimEnd('\')

    $add = {
        param([string]$Title, [string]$File, [string]$LibraryId)
        if (-not $File -or -not [IO.File]::Exists($File)) { return }
        $file = [IO.Path]::GetFullPath($File)
        $key = [string](Get-MusicServerPathKey -Path $file)
        if ($seen.ContainsKey($key)) { return }
        # Stale Navidrome rows from a former library are not current taste.
        if (-not $file.StartsWith(($musicRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $seen[$key] = $true
        if (-not $LibraryId) { $LibraryId = Get-MusicServerLocalIdentity -File $file }
        $canonical = $null
        foreach ($candidate in @(($LibraryId -replace '^library-', ''), $LibraryId, $file, ('file:' + $file))) {
            if ($canonicalMap.ContainsKey($candidate)) { $canonical = $canonicalMap[$candidate]; break }
        }
        $relative = $file.Substring($musicRoot.Length + 1).Replace('\','/').ToLowerInvariant()
        $metadata = $null
        if ($portableIndex.ContainsKey($relative)) {
            try { $metadata = [string]$portableIndex[$relative].metadata_json | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
        if ($canonical -and [string]$canonical.title) {
            $Title = [string]$canonical.title
        } elseif ($metadata) {
            $exact = [string](Get-OptionalProperty $metadata 'canonical_title' '')
            if ($exact -and [string](Get-OptionalProperty $metadata 'canonical_title_source' '') -eq 'netease') {
                $Title = $exact
            } else {
                $portableTitle = [string](Get-OptionalProperty $metadata 'title' (Get-OptionalProperty $metadata 'name' ''))
                if ($portableTitle) { $Title = $portableTitle }
            }
        }
        if ([string]::IsNullOrWhiteSpace($Title)) { return }
        $indexedArtist = ''
        if ($metadata) { $indexedArtist = [string](Get-OptionalProperty $metadata 'artist' '') }
        if (-not $indexedArtist) {
            $parent = [IO.Path]::GetDirectoryName($file)
            if ($parent -ine $musicRoot -and $parent -ine [IO.Path]::GetFullPath($Config.DailyDir).TrimEnd('\')) {
                $indexedArtist = [IO.Path]::GetFileName($parent)
            }
        }
        $cached = if ($resolvedArtists.ContainsKey($key)) { $resolvedArtists[$key] } else { $null }
        $decision = Resolve-DisplayArtist -Title $Title -Indexed $indexedArtist -CachedRow $cached -CanonicalTrack $canonical
        $artist = if ($decision) { [string]$decision.artist } else { '' }
        $trackId = if ($canonical) { [string]$canonical.id } else { Get-CanonicalTrackId -Title $Title -Artist $artist }
        $neteaseId = ''
        if ($canonical) {
            $identifier = @(ConvertFrom-MusicServerJsonArray -Json ([string](Get-OptionalProperty $canonical 'identifiers_json' '[]'))) |
                Where-Object { [string](Get-OptionalProperty $_ 'type' '') -eq 'netease' } | Select-Object -First 1
            if ($identifier) { $neteaseId = [string](Get-OptionalProperty $identifier 'value' '') }
        }
        [void]$rows.Add([pscustomobject]@{
            Title = $Title; Artist = $artist; File = $file; LibraryId = $LibraryId
            TrackId = $trackId; NeteaseId = $neteaseId; ArtistIsResolved = [bool]$artist
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
                & $add ([string]$parts[1]) $file ('library-' + [string]$parts[0])
            }
        } catch { }
        finally {
            foreach ($path in @($tmp, "$tmp-wal", "$tmp-shm")) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # DailyMix contains the user's collected downloads. On another device the
    # like/history DB may not exist yet; dropping the folder would erase every
    # available taste seed. It is weak fallback only, never stronger than LIKE.
    foreach ($entry in @(Get-ChildItem -LiteralPath $Config.MusicDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a','.ogg','.opus' })) {
        & $add $entry.BaseName $entry.FullName ''
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
if ($picked.Count -eq 0) {
    if (-not $DryRun) {
        Initialize-StarterRecommendationsDb -Count $Count | Out-Null
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[selection] source=onboarding_starter reason=no_preference_seeds download_calls=0'
    }
    Write-Host '尚未形成偏好，使用初遇歌单。试听和收藏后会逐步转为个性化推荐。'
    return
}
foreach ($seed in $picked) { Write-Host "    - $($seed.Title) - $($seed.Artist) [$($seed.Source), weight=$($seed.Weight)]" -ForegroundColor DarkGray }
$DailyMetadataState = [pscustomobject]@{
    Clock = [Diagnostics.Stopwatch]::StartNew(); BudgetSeconds = 120
    Calls = 0; ConsecutiveFailures = 0; Blocked = $false; StopReason = ''
}

Write-Step '建立 SQLite 排除集与近期推荐冷却'
$exclude = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $localRows) {
    [void]$exclude.Add((Normalize-MusicText ([string]$row.Title)))
    if ($row.File) { [void]$exclude.Add((Normalize-MusicText ([IO.Path]::GetFileNameWithoutExtension([string]$row.File)))) }
    if ($row.TrackId) { [void]$exclude.Add("track:$($row.TrackId)") }
    if ($row.NeteaseId) { [void]$exclude.Add("netease:$($row.NeteaseId)") }
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

# Disliked songs, resolved once and used by BOTH sources below.
#
# Disliking one song must lower the weight of everything RELATED to it -- its
# singer, its album, songs that sound like it, and anything it seeded -- not only
# that exact recording. The relations are stored so the similarity lookup, which
# costs a network request, is paid once per disliked song rather than every run.
$disliked = @(Get-DislikedTrackKeysDb)
$dislikeRelationMap = @{}
try { $dislikeRelationMap = Get-DislikeRelationMapDb } catch { $dislikeRelationMap = @{} }
$dislikeLookups = 0
$dislikeLookupLimit = 5
$songsPenalized = 0
foreach ($row in $disliked) {
    $expanded = @()
    # Free relations: read straight off the disliked track itself.
    foreach ($name in @(Split-LocalArtistNames -Artist ([string]$row.Artist))) {
        $key = Normalize-MusicText $name
        if ($key) { $expanded += [pscustomobject]@{ Type = 'ARTIST'; Key = $key } }
    }
    $albumKey = Normalize-MusicText ([string]$row.Album)
    if ($albumKey) { $expanded += [pscustomobject]@{ Type = 'ALBUM'; Key = $albumKey } }
    $seedKey = Normalize-MusicText ([string]$row.Title)
    if ($seedKey) { $expanded += [pscustomobject]@{ Type = 'SEED'; Key = $seedKey } }
    if ($expanded.Count -gt 0) {
        Save-DislikeRelationsDb -TrackId ([string]$row.TrackId) -Relations $expanded | Out-Null
    }

    # Similar songs: one bounded NetEase request, only when this track has no
    # SIMILAR relation yet, so a settled dislike is never re-queried.
    $hasSimilar = $false
    if ($dislikeRelationMap.ContainsKey([string]$row.TrackId)) {
        $hasSimilar = @($dislikeRelationMap[[string]$row.TrackId] | Where-Object { [string]$_.Type -eq 'SIMILAR' }).Count -gt 0
    }
    if (-not $hasSimilar -and $row.NeteaseId -and $dislikeLookups -lt $dislikeLookupLimit) {
        $dislikeLookups++
        $similar = if ([string]$row.NeteaseId -match '^\d+$') { @(Get-SimiSongs -SongId ([long]$row.NeteaseId) -Limit 10) } else { @() }
        $relations = @()
        $bootstrapped = @()
        foreach ($song in $similar) {
            $sid = [string](Get-OptionalProperty $song 'id')
            $name = [string](Get-OptionalProperty $song 'name')
            $artists = @(@(Get-OptionalProperty $song 'artists' @()) | ForEach-Object { [string](Get-OptionalProperty $_ 'name' '') } | Where-Object { $_ })
            if ($sid) { $relations += [pscustomobject]@{ Type = 'SIMILAR'; Key = "netease:$sid" } }
            if ($name -and $artists) {
                $pair = Normalize-MusicText "$name$($artists -join ',')"
                if ($pair) {
                    $relations += [pscustomobject]@{ Type = 'SIMILAR'; Key = $pair }
                    # Latch the similar song's own singer and album too, so the
                    # penalty reaches the related artist and not just the one track.
                    foreach ($artistName in @($artists)) {
                        $artistKey = Normalize-MusicText $artistName
                        if ($artistKey) { $bootstrapped += [pscustomobject]@{ Type = 'ARTIST'; Key = $artistKey } }
                    }
                    $albumName = [string](Get-OptionalProperty (Get-OptionalProperty $song 'album' $null) 'name' '')
                    $similarAlbum = Normalize-MusicText $albumName
                    if ($similarAlbum) { $bootstrapped += [pscustomobject]@{ Type = 'ALBUM'; Key = $similarAlbum } }
                }
            }
        }
        $all = @($relations) + @($bootstrapped)
        if ($all.Count -gt 0) { Save-DislikeRelationsDb -TrackId ([string]$row.TrackId) -Relations $all | Out-Null }
        # Only a non-empty answer is remembered as settled; an empty one is retried
        # on a later run rather than permanently claiming "nothing is similar".
        if ($relations.Count -eq 0) { continue }
    }
}
$dislikeRelationMap = @{}
try { $dislikeRelationMap = Get-DislikeRelationMapDb } catch { $dislikeRelationMap = @{} }
$dislikeBuckets = Get-DislikeRelationBuckets -Disliked $disliked -RelationMap $dislikeRelationMap
$bucketsTotal = 0
foreach ($name in @('TRACK','ARTIST','ALBUM','SIMILAR','SEED')) { if ($dislikeBuckets.ContainsKey($name)) { $bucketsTotal += $dislikeBuckets[$name].Count } }
if ($disliked.Count -gt 0) {
    Write-Host "  讨厌歌曲：$($disliked.Count) 首；关联键 $bucketsTotal 个（歌手/专辑/相似/种子）；相似查询 $dislikeLookups 次" -ForegroundColor Yellow
}

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
#
# Off by default (LocalCount = 0): a song the listener already owns is not a
# discovery, so the daily push stays remote-only unless a caller explicitly asks
# for local re-listens.
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
    # The relation penalty is applied inside the selection so an owned track related
    # to a disliked song (same singer, same album) loses its slot to an unrelated
    # one; demoting afterwards would only reorder the picks already chosen.
    $localPicks = @(Select-LocalRecommendationTracks -Candidates @($localCandidates) -Affinity $affinity -ExcludedKeys @($localExclude) -Limit $localBudget -DislikeBuckets $dislikeBuckets -DislikeDivisors $DislikeRelationDivisor)
}
Write-Host "  本地重听推荐：$($localPicks.Count) 首（候选 $($localCandidates.Count) 首，歌手亲和度 $($affinity.Count) 个，预算 $localBudget）" -ForegroundColor Yellow

Write-Step '从网易云生成相似歌曲 metadata'
$candidateMap = @{}
$seedMisses = 0
$knownSeedIds = @{}
foreach ($row in $localRows) {
    if ($row.TrackId -and [string]$row.NeteaseId -match '^\d+$') { $knownSeedIds[[string]$row.TrackId] = [string]$row.NeteaseId }
}
foreach ($seed in $picked) {
    if ($DailyMetadataState.Blocked) { break }
    # Searching the raw uploader title wastes the seed: it is the song name plus
    # channel branding plus the song name again. Each cleaned form is tried with
    # the resolved singer first and alone second, and the search only accepts a
    # candidate whose title matches the query, so a wrong artist cannot be picked.
    $found = @()
    if ($knownSeedIds.ContainsKey([string]$seed.TrackId)) {
        # An exact migrated/downloaded recording id is stronger than a new
        # search and avoids rediscovering a cover or differently credited version.
        $found = @([pscustomobject]@{ id = $knownSeedIds[[string]$seed.TrackId] })
    }
    $queries = if ($found.Count) { @() } else { @(Get-SongSearchQueries -Title ([string]$seed.Title) -Artist ([string]$seed.Artist)) }
    foreach ($query in $queries) {
        $hits = @(Search-Netease -Keyword $query -Limit 3)
        if ($DailyMetadataState.Blocked) { break }
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
Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message "[metadata] calls=$($DailyMetadataState.Calls) elapsed_ms=$($DailyMetadataState.Clock.ElapsedMilliseconds) stop_reason=$($DailyMetadataState.StopReason) budget_seconds=120"

# Candidates related to a disliked song are pushed down rather than removed, by
# how close the relation is. "少推荐" is a soft penalty: a related song keeps a much
# lower score than an unrelated one, so it sinks out of the day under normal
# circumstances but can still appear when there is nothing better -- which is what
# excluding it outright would prevent.
$dislikeByRelation = @{}
if ($bucketsTotal -gt 0) {
    foreach ($candidate in @($candidateMap.Values)) {
        $relation = Get-CandidateDislikeRelation -Title ([string]$candidate.Title) -Artist ([string]$candidate.Artist) `
            -Album ([string]$candidate.Album) -NeteaseId ([string]$candidate.NeteaseId) `
            -FromSeed ([string]$candidate.FromSeed) -Buckets $dislikeBuckets
        if (-not $relation) { continue }
        $amount = 0
        if ($DislikeRelationPenalty.ContainsKey($relation)) { $amount = [int]$DislikeRelationPenalty[$relation] }
        if ($amount -le 0) { continue }
        $candidate.Score = $candidate.Score - $amount
        $songsPenalized++
        if ($dislikeByRelation.ContainsKey($relation)) { $dislikeByRelation[$relation]++ } else { $dislikeByRelation[$relation] = 1 }
    }
    $summary = @($dislikeByRelation.Keys | Sort-Object | ForEach-Object { "$_=$($dislikeByRelation[$_])" }) -join ' '
    Write-Host "  关联降权：$songsPenalized 首（$summary）" -ForegroundColor Yellow
}

$ranked = @($candidateMap.Values | Sort-Object @{Expression = {$_.Score}; Descending = $true}, @{Expression = { Get-Random }})
# Probe only a diverse shortlist, with both request-count and wall-clock limits.
# DryRun stays read-only; unavailable requests are UNKNOWN, never "no lyrics".
$shortlist=@(Select-QualityRemoteRecommendations -Candidates $ranked -Count ([Math]::Min(60, [Math]::Max(20,$Count * 3))))
foreach ($candidate in $ranked) { $candidate | Add-Member -NotePropertyName LyricQuality -NotePropertyValue 'UNKNOWN' -Force }
$qualityClock=[Diagnostics.Stopwatch]::StartNew(); $probes=0
foreach ($candidate in $shortlist) {
    $cacheOnly=$DryRun -or $probes -ge 40 -or $qualityClock.Elapsed.TotalSeconds -ge 45
    $evidence=Get-RecommendationLyricEvidence -Config $Config -SongId $candidate.NeteaseId -CacheOnly:$cacheOnly
    if (-not $cacheOnly) { $probes++ }
    $candidate | Add-Member -NotePropertyName LyricQuality -NotePropertyValue $evidence.status -Force
}
$recos = @(Select-QualityRemoteRecommendations -Candidates $ranked -Count ([Math]::Max(0, $Count - @($localPicks).Count)))
$qualitySummary=@($recos | Group-Object LyricQuality | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
$liveSelected=@($recos | Where-Object { (Get-RecommendationQualityTier $_).Live }).Count
Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message "[quality] live=$liveSelected lyric_checks=$probes elapsed_ms=$($qualityClock.ElapsedMilliseconds) $qualitySummary"
Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message "[selection] candidates=$($ranked.Count) selected=$($recos.Count) local=$(@($localPicks).Count) target=$Count diversity=credited_artist dislike_penalized=$songsPenalized"

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
    if ($DailyMetadataState.Blocked -and $DailyMetadataState.StopReason -ne 'metadata_budget' -and @(Get-TodayRecommendationsDb -Date $today).Count -gt 0) {
        # A partly successful provider run is still a failed refresh. Keep a
        # complete existing day (including a starter day) until a healthy retry.
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message "[selection] metadata_failed=true stop_reason=$($DailyMetadataState.StopReason) preserved_existing_day=true library_revision_pending=true"
        return
    }
    if ($recommendations.Count -eq 0) {
        Initialize-StarterRecommendationsDb -Count $Count | Out-Null
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[selection] empty_result preserved_existing_day=true starter_fallback=true'
        return
    }
    $currentMusicDir = Get-MusicServerPathKey -Path (Resolve-ConfiguredMusicDir -Config $Config)
    if ($currentMusicDir -ne $RecommendationMusicDir -or [string](Get-AppSettingDb -Key 'recommendation_library_pending') -ne $RecommendationLibraryRevision) {
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[generation] skipped=library_changed_during_discovery preserved_existing_day=true'
        return
    }
    $saveResult = Save-DailyRecommendationsDb -Recommendations $recommendations -Tracks $tracks -Date $today -EnforceLibraryRevision -ExpectedLibraryRevision $RecommendationLibraryRevision
    if ($saveResult.Skipped) {
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message '[generation] skipped=library_revision_changed_during_save preserved_existing_day=true'
        return
    }
    Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-recommendation.log') -Message "[selection] completed=true library_count=$($localRows.Count) seed_count=$($picked.Count) remote_count=$($recommendations.Count - $localAdded) local_count=$localAdded seed_misses=$seedMisses library_revision_ack=$([bool]$RecommendationLibraryRevision) download_calls=0"
    Write-MusicServerEventDb -EventType 'RECOMMENDATIONS_GENERATED' -Result 'SUCCESS' -Message "count=$($recommendations.Count); download_calls=0; feedback=explicit_only; cooldown_days=$RecommendationCooldownDays"
    Write-Host "`n已原子保存 SQLite CanonicalTrack、DailyRecommendation 和 DISPLAY。" -ForegroundColor Green
} else {
    Write-Host "`n【DryRun 模式，未写 recommendation 状态】" -ForegroundColor Magenta
}
Write-Host '推荐阶段不会调用 yt-dlp、Bilibili 下载、ffprobe、歌词下载或 Navidrome 扫描。' -ForegroundColor Cyan
} finally {
    if ($OwnsRecommendationMutex) { $RecommendationMutex.ReleaseMutex() }
    $RecommendationMutex.Dispose()
}
