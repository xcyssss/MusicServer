<#
.SYNOPSIS
    日推次日清理 - 保留你点了♥的歌，删除其余的并记入黑名单
.DESCRIPTION
    流程：
      1. 读取 DailyMix 目录里的所有日推歌曲
      2. 查 Navidrome 数据库，看哪些被星标(♥)过
      3. 星标的 -> 移动到主音乐库 Music\，记入 accepted.csv（作为未来推荐种子）
      4. 未星标的 -> 删除文件，记入 rejected.csv（永不再推）
      5. 触发 Navidrome 扫描
.PARAMETER DryRun
    只显示将要执行的操作，不实际移动/删除
.PARAMETER KeepDays
    保留最近 N 天的日推不清理（默认 1，即只清理今天之前的）
#>
param(
    [switch]$DryRun,
    [int]$KeepDays = 1
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root      = 'E:\Project\MusicServer'
$MusicDir  = "$Root\Music"
$DailyDir  = "$MusicDir\DailyMix"
$DataDir   = "$Root\DailyMix_data"
$Blacklist = "$DataDir\rejected.csv"
$Accepted  = "$DataDir\accepted.csv"
$NdDb      = "$Root\Navidrome\Data\navidrome.db"
$Sqlite    = 'sqlite3'
$TodayM3u  = "$MusicDir\每日推荐.m3u"
$KeepM3u   = "$MusicDir\日推精选.m3u"
$NavidromeExe = "$Root\Navidrome\bin\navidrome.exe"
$NavidromeCfg = "$Root\Navidrome\navidrome.toml"

. "$Root\lib_playlist.ps1"
Import-Module (Join-Path $Root 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.State.psm1') -Force
$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
Initialize-MusicServerDatabase -DbPath (Join-Path $Config.StateDir 'musicserver.db') -SqliteExe $Config.Sqlite
Initialize-MusicServerSchema
$Sqlite = $Config.Sqlite

function Write-Step($m) { Write-Host "`n>>> $m" -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $DailyDir)) {
    Write-Host "日推目录不存在，无需清理" -ForegroundColor Yellow
    exit 0
}

$files = Get-ChildItem -LiteralPath $DailyDir -Filter *.mp3
if ($files.Count -eq 0) {
    Write-Host "日推目录为空，无需清理" -ForegroundColor Yellow
    exit 0
}

Write-Step "日推目录中有 $($files.Count) 首歌"

# ---------- 读取星标状态 ----------
Write-Step "查询 Navidrome 星标(♥)状态"

$starredPaths = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path -LiteralPath $NdDb) {
    $tmpDb = Join-Path $env:TEMP "nd_clean_$(Get-Random).db"
    Copy-Item -LiteralPath $NdDb -Destination $tmpDb -Force
    # WAL 里可能有未合并的星标操作，一起复制
    foreach ($ext in @('-wal','-shm')) {
        $w = "$NdDb$ext"
        if (Test-Path -LiteralPath $w) { Copy-Item -LiteralPath $w -Destination "$tmpDb$ext" -Force -EA SilentlyContinue }
    }
    try {
        $q = "select mf.path from annotation a join media_file mf on mf.id=a.item_id where a.item_type='media_file' and a.starred=1;"
        $out = & $Sqlite $tmpDb $q 2>$null
        foreach ($line in @($out)) {
            if ($line) { [void]$starredPaths.Add((Split-Path $line -Leaf)) }
        }
    } catch { Write-Host "  查询失败: $($_.Exception.Message)" -ForegroundColor Red }
    Remove-Item "$tmpDb*" -Force -EA SilentlyContinue
}
Write-Host "  全库星标数: $($starredPaths.Count)" -ForegroundColor Green

# ---------- 从 SQLite 获取日推文件元数据 ----------
$fileMap = @{}
foreach ($row in @(Get-RecommendationFilesDb)) {
    if ($row.file_name) { $fileMap[[string]$row.file_name] = $row }
}

$today = Get-Date -Format 'yyyy-MM-dd'
$keepList = @()
$dropList = @()

foreach ($f in $files) {
    $meta = $fileMap[$f.Name]
    # 当天下载的先不动，给你时间听
    if ($meta -and $meta.Date -eq $today -and $KeepDays -ge 1) {
        Write-Host ("  [今日] {0} — 暂不处理" -f $f.BaseName) -ForegroundColor DarkGray
        continue
    }
    if ($starredPaths.Contains($f.Name)) {
        $keepList += [PSCustomObject]@{ File = $f; Meta = $meta }
    } else {
        $dropList += [PSCustomObject]@{ File = $f; Meta = $meta }
    }
}

Write-Step "处理计划"
Write-Host ("  保留(已♥): {0}" -f $keepList.Count) -ForegroundColor Green
foreach ($k in $keepList) { Write-Host ("    + {0}" -f $k.File.BaseName) -ForegroundColor Green }
Write-Host ("  删除(未♥): {0}" -f $dropList.Count) -ForegroundColor Yellow
foreach ($d in $dropList) { Write-Host ("    - {0}" -f $d.File.BaseName) -ForegroundColor DarkYellow }

if ($DryRun) {
    Write-Host "`n【DryRun，未做任何改动】" -ForegroundColor Magenta
    exit 0
}

# ---------- 保留的移入主库 ----------
if ($keepList.Count -gt 0) {
    Write-Step "把喜欢的歌移入主音乐库"
    $accRows = @()
    foreach ($k in $keepList) {
        $trackId = if ($k.Meta -and $k.Meta.track_id) { [string]$k.Meta.track_id } else { Get-CanonicalTrackId -Title $k.File.BaseName -Artist '' }
        $title = if ($k.Meta) { [string]$k.Meta.title } else { $k.File.BaseName }
        $artist = if ($k.Meta) { [string]$k.Meta.artist } else { '' }
        $neteaseId = if ($k.Meta) { [string]$k.Meta.netease_id } else { '' }
        $acceptedAt = Get-Date -Format 'yyyy-MM-dd'
        $fileDate = if ($k.Meta) { [string]$k.Meta.date } else { $acceptedAt }
        $album = if ($k.Meta) { [string]$k.Meta.album } else { '' }
        $duration = if ($k.Meta) { [int]$k.Meta.duration } else { 0 }
        $seedSource = if ($k.Meta) { [string]$k.Meta.seed_source } else { 'daily_cleanup' }
        $acceptedValue = ConvertTo-Json -InputObject ([ordered]@{
                legacy_key = "cleanup_accepted:$($k.File.Name):$trackId"
                title = $title; artist = $artist; netease_id = $neteaseId; file = [string]$k.File.Name
                accepted_at = $acceptedAt; positive = $true
            }) -Compress -Depth 10
        try {
            # SQLite is committed before the irreversible filesystem action.
            # A failed compatibility export or later retry cannot undo this fact.
            Write-FeedbackIfAbsentDb -TrackId $trackId -FeedbackType 'ACCEPTED' `
                -Source 'daily_cleanup' -Value $acceptedValue | Out-Null
            Save-RecommendationFileDb -FileName ([string]$k.File.Name) -TrackId $trackId `
                -Date $fileDate `
                -NeteaseId $neteaseId -Title $title -Artist $artist `
                -Album $album -Duration $duration -SeedSource $seedSource | Out-Null
        } catch {
            throw "SQLite acceptance failed for $($k.File.Name): $($_.Exception.Message)"
        }
        $dest = Join-Path $MusicDir $k.File.Name
        if (Test-Path -LiteralPath $dest) {
            Write-Host ("  主库已有同名，跳过: {0}" -f $k.File.Name) -ForegroundColor DarkGray
        } else {
            Move-Item -LiteralPath $k.File.FullName -Destination $dest -Force -ErrorAction Stop
            # 歌词一起搬
            $lrc = [System.IO.Path]::ChangeExtension($k.File.FullName, '.lrc')
            if (Test-Path -LiteralPath $lrc) {
                Move-Item -LiteralPath $lrc -Destination ([System.IO.Path]::ChangeExtension($dest, '.lrc')) -Force -ErrorAction Stop
            }
            Write-Host ("  移入: {0}" -f $k.File.BaseName) -ForegroundColor Green
        }
        $accRows += [PSCustomObject]@{
            AcceptedAt = $acceptedAt; NeteaseId = $neteaseId
            Title = $title; Artist = $artist; File = $k.File.Name
        }
    }
    if ($accRows.Count -gt 0) {
        try {
            if (Test-Path -LiteralPath $Accepted) {
                $accRows | Export-Csv -Path $Accepted -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
            } else {
                $accRows | Export-Csv -Path $Accepted -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }
        } catch {
            Write-Warning "LEGACY_WRITE_ONLY_COMPAT accepted.csv export failed: $($_.Exception.Message)"
        }
        Write-Host ("  已记入 accepted.csv ({0} 条)" -f $accRows.Count) -ForegroundColor Green
    }
}

# ---------- 未星标的删除 + 入黑名单 ----------
if ($dropList.Count -gt 0) {
    Write-Step "删除未被喜欢的歌，并记入黑名单"
    $rejRows = @()
    foreach ($d in $dropList) {
        $lrc = [System.IO.Path]::ChangeExtension($d.File.FullName, '.lrc')
        if ($d.Meta) {
            $rejRows += [PSCustomObject]@{
                RejectedAt = (Get-Date -Format 'yyyy-MM-dd')
                NeteaseId  = $d.Meta.netease_id
                Title      = $d.Meta.title
                Artist     = $d.Meta.artist
                FromSeed   = $d.Meta.seed_source
            }
        } else {
            $rejRows += [PSCustomObject]@{
                RejectedAt = (Get-Date -Format 'yyyy-MM-dd')
                NeteaseId  = ''
                Title      = $d.File.BaseName
                Artist     = ''
                FromSeed   = ''
            }
        }
        $rejectedTrackId = if ($d.Meta -and $d.Meta.track_id) { [string]$d.Meta.track_id } else { Get-CanonicalTrackId -Title $rejRows[-1].Title -Artist $rejRows[-1].Artist }
        if ($rejectedTrackId) {
            $rejectedValue = ConvertTo-Json -InputObject ([ordered]@{
                    legacy_key = "cleanup_rejected:$($d.File.Name):$rejectedTrackId"
                    title = [string]$rejRows[-1].Title; artist = [string]$rejRows[-1].Artist
                    netease_id = [string]$rejRows[-1].NeteaseId; file = [string]$d.File.Name
                    rejected_at = (Get-Date -Format 'yyyy-MM-dd'); positive = $false
                }) -Compress -Depth 10
            try {
                # Commit the SQLite blacklist before the irreversible delete.
                Write-FeedbackIfAbsentDb -TrackId $rejectedTrackId -FeedbackType 'REJECTED' `
                    -Source 'daily_cleanup' -Value $rejectedValue | Out-Null
            } catch {
                throw "SQLite rejection failed for $($d.File.Name): $($_.Exception.Message)"
            }
        }
        Remove-Item -LiteralPath $d.File.FullName -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $lrc) { Remove-Item -LiteralPath $lrc -Force -ErrorAction Stop }
        Write-Host ("  删除: {0}" -f $d.File.BaseName) -ForegroundColor DarkYellow
    }
    try {
        if (Test-Path -LiteralPath $Blacklist) {
            $rejRows | Export-Csv -Path $Blacklist -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
        } else {
            $rejRows | Export-Csv -Path $Blacklist -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        }
    } catch {
        Write-Warning "LEGACY_WRITE_ONLY_COMPAT rejected.csv export failed: $($_.Exception.Message)"
    }
    Write-Host ("  已记入 rejected.csv ({0} 条，永不再推)" -f $rejRows.Count) -ForegroundColor Yellow
}

# ---------- 重建播放列表 ----------
Write-Step "重建播放列表"

# 「每日推荐」= DailyMix 里剩下的（今天还没清理的）
$remain = @(Get-ChildItem -LiteralPath $DailyDir -Filter *.mp3 -EA SilentlyContinue)
$todayTracks = foreach ($f in $remain) {
    $m = $fileMap[$f.Name]
    @{
        File     = $f.FullName
        Title    = if ($m) { $m.title } else { $f.BaseName }
        Artist   = if ($m) { $m.artist } else { '' }
        Duration = if ($m) { $m.duration } else { 0 }
    }
}
$n1 = Write-M3u -Path $TodayM3u -Name "每日推荐 $(Get-Date -Format 'MM-dd')" -Tracks @($todayTracks) `
    -Comment "由 daily_cleanup.ps1 重建于 $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host ("  每日推荐: {0} 首" -f $n1) -ForegroundColor Green

# 「日推精选」= 历史上所有点过 ♥ 并已移入主库的歌
$keepTracks = @()
$seen = New-Object System.Collections.Generic.HashSet[string]
foreach ($feedback in @(Get-RecommendationFeedbackDb -FeedbackType 'ACCEPTED')) {
    $a = Convert-RecommendationFeedbackValue -Value ([string]$feedback.value)
    if (-not $a -or -not $a.file -or -not $seen.Add([string]$a.file)) { continue }
    $p = Join-Path $MusicDir ([string]$a.file)
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $keepTracks += @{ File = $p; Title = [string]$a.title; Artist = [string]$a.artist; Duration = 0 }
}
$n2 = Write-M3u -Path $KeepM3u -Name '日推精选' -Tracks @($keepTracks) `
    -Comment "所有点过 ♥ 的日推歌曲，更新于 $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host ("  日推精选: {0} 首" -f $n2) -ForegroundColor Green

# ---------- 全量扫描，清理已经删除的旧索引 ----------
if (Test-Path -LiteralPath $NavidromeExe -and Test-Path -LiteralPath $NavidromeCfg) {
    Write-Step "执行 Navidrome 全量扫描，清理已删除歌曲"
    $scanOutput = @(& $NavidromeExe -c $NavidromeCfg scan --full --nobanner 2>&1)
    $scanExit = $LASTEXITCODE
    if ($scanExit -eq 0) {
        Write-Host "  全量扫描完成，已删除文件不会继续显示" -ForegroundColor Green
    } else {
        Write-Host ("  全量扫描失败，退出码: {0}" -f $scanExit) -ForegroundColor Red
        $scanOutput | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
    }
}

Write-Host ""
Write-Host "==================== 清理完成 ====================" -ForegroundColor Cyan
Write-Host ("  保留: {0} 首（已移入主库）" -f $keepList.Count) -ForegroundColor Green
Write-Host ("  删除: {0} 首（已入黑名单）" -f $dropList.Count) -ForegroundColor Yellow
$totalAcc = @(Get-RecommendationFeedbackDb -FeedbackType 'ACCEPTED').Count
$totalRej = @(Get-RecommendationFeedbackDb -FeedbackType 'REJECTED').Count
Write-Host ("  累计喜欢: {0} | 累计拒绝: {1}" -f $totalAcc, $totalRej)
Write-Host "=================================================" -ForegroundColor Cyan
