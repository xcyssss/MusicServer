<#
.SYNOPSIS
    每日音乐推荐：只生成远程推荐和试听元数据，不下载音频。
.DESCRIPTION
    兼容现有 accepted.csv、lyrics_report.csv 和 Navidrome 本地库作为推荐种子。
    推荐阶段只访问网易云的轻量 metadata API；Bilibili/yt-dlp 只允许由 wanted_worker.ps1
    在用户明确点红心后调用。
.PARAMETER Count
    目标推荐数量，默认 20。
.PARAMETER DryRun
    只打印推荐，不写 JSON/CSV 状态。
.PARAMETER SeedCount
    使用的种子数量，默认 25。
.PARAMETER Root
    项目根目录；默认当前脚本所在目录，主要用于测试和迁移。
#>
param(
    [int]$Count = 20,
    [switch]$DryRun,
    [int]$SeedCount = 25,
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
Import-LegacyRecommendationState -Config $Config | Out-Null

$Headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
    'Referer'    = 'https://music.163.com/'
}
$Accepted = Join-Path $Config.DataDir 'accepted.csv'
$Blacklist = Join-Path $Config.DataDir 'rejected.csv'
$History = Join-Path $Config.DataDir 'history.csv'
$Report = Join-Path $Config.Root 'lyrics_report.csv'

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
    $seeds = @()
    if (Test-Path -LiteralPath $Accepted) {
        foreach ($row in @(Import-Csv -LiteralPath $Accepted -Encoding UTF8)) {
            if ($row.Title) {
                $seeds += [pscustomobject]@{ Title = $row.Title; Artist = $row.Artist; Weight = 3; Source = 'accepted' }
            }
        }
    }
    if (Test-Path -LiteralPath $History) {
        foreach ($row in @(Import-Csv -LiteralPath $History -Encoding UTF8 | Where-Object { $_.Title })) {
            $seeds += [pscustomobject]@{ Title = $row.Title; Artist = $row.Artist; Weight = 2; Source = 'legacy_history' }
        }
    }
    foreach ($row in @(Read-StateCollection -Config $Config -Name recommendation_history | Where-Object { $_.title })) {
        $seeds += [pscustomobject]@{ Title = $row.title; Artist = $row.artist; Weight = 2; Source = 'recommendation_history' }
    }
    $starred = @(Get-StarredTitles)
    foreach ($line in $starred) {
        $parts = [string]$line -split ' - ', 2
        $seeds += [pscustomobject]@{ Title = $parts[0]; Artist = if ($parts.Count -gt 1) { $parts[1] } else { '' }; Weight = 3; Source = 'navidrome_star' }
    }
    if (Test-Path -LiteralPath $Report) {
        foreach ($row in @(Import-Csv -LiteralPath $Report -Encoding UTF8 | Where-Object { $_.Matched -and $_.Status -in @('OK','NO_LYRIC') })) {
            $seeds += [pscustomobject]@{ Title = $row.Matched; Artist = $row.MatchedArtist; Weight = 1; Source = 'library' }
        }
    }

    $expanded = foreach ($seed in $seeds) {
        for ($i = 0; $i -lt [Math]::Max(1, [int]$seed.Weight); $i++) { $seed }
    }
    $picked = @()
    $artists = @{}
    foreach ($seed in @($expanded | Sort-Object { Get-Random })) {
        if (-not $seed.Title) { continue }
        $artistKey = Normalize-MusicText (($seed.Artist -split '[,，、]')[0])
        if ($artists.ContainsKey($artistKey) -and $artists[$artistKey] -ge 3) { continue }
        if (@($picked | Where-Object { (Normalize-MusicText $_.Title) -eq (Normalize-MusicText $seed.Title) -and (Normalize-MusicText $_.Artist) -eq (Normalize-MusicText $seed.Artist) }).Count -gt 0) { continue }
        $picked += $seed
        if ($artists.ContainsKey($artistKey)) { $artists[$artistKey]++ } else { $artists[$artistKey] = 1 }
        if ($picked.Count -ge $SeedCount) { break }
    }
    return @($picked)
}

Write-Step '收集种子歌曲'
$picked = @(Get-SeedPool)
Write-Host "  本次选用种子：$($picked.Count)" -ForegroundColor Yellow
foreach ($seed in $picked) { Write-Host "    - $($seed.Title) - $($seed.Artist)" -ForegroundColor DarkGray }

Write-Step '建立排除集'
$exclude = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in @(Get-ChildItem -LiteralPath $Config.MusicDir -Filter '*.mp3' -File -Recurse -ErrorAction SilentlyContinue)) {
    [void]$exclude.Add((Normalize-MusicText $file.BaseName))
}
if (Test-Path -LiteralPath $Blacklist) {
    foreach ($row in @(Import-Csv -LiteralPath $Blacklist -Encoding UTF8)) {
        if ($row.Title) { [void]$exclude.Add((Normalize-MusicText $row.Title)) }
        if ($row.NeteaseId) { [void]$exclude.Add("netease:$($row.NeteaseId)") }
    }
}
$acceptedIds = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path -LiteralPath $Accepted) {
    foreach ($row in @(Import-Csv -LiteralPath $Accepted -Encoding UTF8)) {
        if ($row.NeteaseId) { [void]$acceptedIds.Add([string]$row.NeteaseId) }
    }
}
Write-Host "  排除条目：$($exclude.Count)，已接受网易云 ID：$($acceptedIds.Count)" -ForegroundColor Yellow

Write-Step '从网易云生成相似歌曲 metadata'
$candidateMap = @{}
foreach ($seed in $picked) {
    $found = @(Search-Netease -Keyword "$($seed.Title) $($seed.Artist)" -Limit 1)
    if ($found.Count -eq 0) { continue }
    $similar = @(Get-SimiSongs -SongId ([long]$found[0].id) -Limit 10)
    foreach ($song in $similar) {
        $sid = [string]$song.id
        if (-not $sid -or $acceptedIds.Contains($sid)) { continue }
        if ($candidateMap.ContainsKey($sid)) { $candidateMap[$sid].Score++; continue }
        $artist = (($song.artists | ForEach-Object { $_.name }) -join ',')
        $duration = [int]($song.duration / 1000)
        if ($duration -lt 60 -or $duration -gt 600) { continue }
        if ($song.name -match '合集|串烧|伴奏|instrumental|纯音乐|Cover |cover版|铃声|remix版|片段|试听|DJ版|女声版|男声版|慢搖|抖音版|加速版|减速版|清唱') { continue }
        if ($artist -match 'Cover|翻唱') { continue }
        $key = Normalize-MusicText "$($song.name)$artist"
        if ($exclude.Contains($key) -or $exclude.Contains((Normalize-MusicText $song.name))) { continue }
        $candidateMap[$sid] = [pscustomobject]@{
            NeteaseId = $sid; Title = [string]$song.name; Artist = $artist; Album = [string]$song.album.name
            Duration = $duration; FromSeed = [string]$seed.Title; Score = 1; CoverUrl = [string]$song.album.picUrl
        }
    }
}

$ranked = @($candidateMap.Values | Sort-Object @{Expression = {$_.Score}; Descending = $true}, @{Expression = { Get-Random }})
$recos = @()
$artists = @{}
foreach ($candidate in $ranked) {
    $artistKey = Normalize-MusicText (($candidate.Artist -split '[,，、]')[0])
    if ($artists.ContainsKey($artistKey) -and $artists[$artistKey] -ge 5) { continue }
    $recos += $candidate
    if ($artists.ContainsKey($artistKey)) { $artists[$artistKey]++ } else { $artists[$artistKey] = 1 }
    if ($recos.Count -ge $Count) { break }
}

$today = Get-TodayDate
$recommendations = @()
$rank = 0
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
    $recommendations += [pscustomobject]@{
        id = "rec_${today}_${rank}_$($trackId.Substring(6, 12))"
        date = $today; track_id = $trackId; netease_id = $candidate.NeteaseId
        title = $candidate.Title; artist = $candidate.Artist; album = $candidate.Album
        duration = $candidate.Duration; rank = $rank; reason = "相似于：$($candidate.FromSeed)"
        playback_source = "netease:$($candidate.NeteaseId)"; preview_sources = $preview
        liked = $false; created_at = Get-NowIso; updated_at = Get-NowIso
    }
    if (-not $DryRun) { Save-CanonicalTrack -Config $Config -Track $track | Out-Null }
}

Write-Host "`n候选推荐：$($candidateMap.Count) 首，取前 $($recommendations.Count) 首" -ForegroundColor Green
foreach ($r in $recommendations) {
    Write-Host ("  {0,2}. {1} - {2} ({3}s) | {4}" -f $r.rank, $r.title, $r.artist, $r.duration, $r.playback_source) -ForegroundColor White
}

if (-not $DryRun) {
    Save-DailyRecommendations -Config $Config -Recommendations $recommendations -Date $today
    Write-StructuredEvent -Config $Config -Event 'RECOMMENDATIONS_GENERATED' -Result 'SUCCESS' -Message "count=$($recommendations.Count); download_calls=0"
    Write-Host "`n已保存 CanonicalTrack、DailyRecommendation 和兼容 today.csv。" -ForegroundColor Green
} else {
    Write-Host "`n【DryRun 模式，未写状态】" -ForegroundColor Magenta
}
Write-Host '推荐阶段不会调用 yt-dlp、Bilibili 下载、ffprobe、歌词下载或 Navidrome 扫描。' -ForegroundColor Cyan
