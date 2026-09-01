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
.PARAMETER Root
    项目根目录；默认当前脚本所在目录，主要用于测试和迁移。
.PARAMETER RandomSeed
    可选测试随机种子；默认使用正常随机行为。
##>
param(
    [int]$Count = 20,
    [switch]$DryRun,
    [int]$SeedCount = 25,
    [string]$Root = $PSScriptRoot,
    [int]$RandomSeed = -1,
    [switch]$MigrateLegacy
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Migration.psm1') -Force

$Config = New-MusicServerConfig -Root $Root
$dbPath = Join-Path $Config.StateDir 'musicserver.db'
if ($DryRun) {
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        throw "DryRun requires an existing SQLite database: $dbPath"
    }
    Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
} else {
    Initialize-MusicServerState -Config $Config
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
    Initialize-MusicServerSchema
}

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
    $starred = @(Get-StarredTitles)
    return @(Get-RecommendationSeedCandidatesDb -SeedCount $SeedCount -NavidromeStars $starred -RandomSeed $RandomSeed)
}

Write-Step '收集 SQLite 种子歌曲'
$picked = @(Get-SeedPool)
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

Write-Step '从网易云生成相似歌曲 metadata'
$candidateMap = @{}
foreach ($seed in $picked) {
    $found = @(Search-Netease -Keyword "$($seed.Title) $($seed.Artist)" -Limit 1)
    if ($found.Count -eq 0) { continue }
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
        }
    }
}

$ranked = @($candidateMap.Values | Sort-Object @{Expression = {$_.Score}; Descending = $true}, @{Expression = { Get-Random }})
$recos = @(); $artists = @{}
foreach ($candidate in $ranked) {
    $artistKey = Normalize-MusicText (($candidate.Artist -split '[,，、]')[0])
    if ($artistKey -and $artists.ContainsKey($artistKey) -and $artists[$artistKey] -ge 5) { continue }
    $recos += $candidate
    if ($artistKey) { if ($artists.ContainsKey($artistKey)) { $artists[$artistKey]++ } else { $artists[$artistKey] = 1 } }
    if ($recos.Count -ge $Count) { break }
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
        -PreviewSources $preview -DownloadCandidates $downloadCandidates -Status 'REMOTE'
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
