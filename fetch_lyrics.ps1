<#
.SYNOPSIS
    为音乐库批量抓取 LRC 歌词（网易云音乐源）
.DESCRIPTION
    从文件名生成多个候选查询 -> 搜索网易云 -> 时长+名称相似度打分 -> 写入同名 .lrc
    Navidrome 会自动读取同名 .lrc 作为歌词
.PARAMETER DryRun
    只预览匹配结果，不写任何文件
.PARAMETER Limit
    只处理前 N 个文件（测试用）
.PARAMETER Force
    覆盖已存在的 .lrc
.PARAMETER Filter
    只处理文件名匹配该通配符的文件
#>
param(
    [switch]$DryRun,
    [int]$Limit = 0,
    [switch]$Force,
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$MusicDir = 'E:\Project\MusicServer\Music'
$FFprobe  = 'C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe'
$Report   = 'E:\Project\MusicServer\lyrics_report.csv'
$Headers  = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
    'Referer'    = 'https://music.163.com/'
}

# 噪声词：UP主宣传语、画质标记等
$NoiseWords = @(
    '在百万豪装录音棚大声听', '百万豪装录音棚大声听', '百万级装备试听',
    'Hi-Res无损音质', 'Hi-res', 'Hi-Res', '无损音质', '无损臻享',
    '附歌词中字', '附中日歌词', '附歌词', '动态歌词排版', '动态水印',
    'FULL', 'BD中字', '中字', '单曲纯享', 'MV', 'Official Music Video',
    'OfficialMusicVideo', '4K60fps', '4K60P', '黑胶', '完美',
    '百万豪装', '录音棚', '大声听', '试听', '翻唱', '纯享版', '静享版',
    '中文字幕', '中英字幕', '直播', 'Live', 'Cover'
)

function Get-Candidates {
    param([string]$Name)

    $s = $Name

    # 分P 标记: "... p01 真实曲名" -> 优先用后半
    $pPart = $null
    if ($s -match '\sp\d{2}\s+(.+)$') {
        $pPart = $Matches[1].Trim()
        $s = $s -replace '\sp\d{2}\s+.+$', ''
    }

    # 去掉方括号/花括号内容
    $s = $s -replace '【[^】]*】', ' '
    $s = $s -replace '\[[^\]]*\]', ' '
    foreach ($w in $NoiseWords) {
        $s = $s -replace [regex]::Escape($w), ' '
    }
    $s = $s -replace '[（(]\s*[）)]', ' '
    $s = $s -replace '\s+', ' '
    $s = $s.Trim(' ', '-', '_', '.', '|', [char]0xFF5C, [char]0x2014, [char]0x2013)

    $cands = New-Object System.Collections.Generic.List[string]
    function Add-Cand($v) {
        if ([string]::IsNullOrWhiteSpace($v)) { return }
        $v = ($v -replace '\s+', ' ').Trim(' ', '-', '_', '.', '|', ':', [char]0xFF5C, [char]0x2014)
        # 去掉曲名尾部的括号补充说明
        $v2 = ($v -replace '[（(][^）)]*[）)]\s*$', '').Trim()
        if ($v.Length -ge 2 -and -not $cands.Contains($v)) { $cands.Add($v) }
        if ($v2.Length -ge 2 -and -not $cands.Contains($v2)) { $cands.Add($v2) }
    }

    # 分P 后缀是最可靠的曲名
    if ($pPart) { Add-Cand $pPart }

    # 所有书名号/引号内的片段（可能是曲名，也可能是专辑名，都试）
    $quoted = @()
    foreach ($m in [regex]::Matches($s, '[《「『”"]([^》」』”"]{2,})[》」』”"]')) {
        $quoted += $m.Groups[1].Value.Trim()
    }

    # 书名号后面剩余的内容（形如《明日方舟》EP - All by My Design）
    $afterQuote = $s -replace '^.*[》」』]', ''
    $afterQuote = $afterQuote -replace '^\s*(EP|OST|ost)\s*[-–—]?\s*', ''
    Add-Cand $afterQuote

    # 破折号两侧
    if ($s -match '^(.+?)\s*[-–—]\s*(.+)$') {
        Add-Cand $Matches[2]
        Add-Cand $Matches[1]
    }

    # 引号内片段（长度短的更可能是曲名，优先）
    foreach ($qq in ($quoted | Sort-Object Length)) { Add-Cand $qq }

    # 兜底：整串
    Add-Cand $s

    # 提取可能的艺术家：第一个书名号之前的内容
    $artist = ''
    if ($s -match '^([^《「『]{1,20})[《「『]') {
        $artist = ($Matches[1] -split '[&,，、/／]')[0].Trim()
    }

    [PSCustomObject]@{ Candidates = $cands; Artist = $artist; Clean = $s }
}

function Search-NetEase {
    param([string]$Keyword, [int]$Cnt = 5)
    $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($Keyword))&type=1&limit=$Cnt"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 20
        if ($r.result -and $r.result.songs) { return @($r.result.songs) }
    } catch { }
    return @()
}

function Get-NetEaseLyric {
    param([long]$SongId)
    $url = "https://music.163.com/api/song/lyric?id=$SongId&lv=1&kv=1&tv=-1"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 20
        $tl = $null
        if ($r.tlyric -and $r.tlyric.lyric) { $tl = $r.tlyric.lyric }
        return [PSCustomObject]@{ Lrc = $r.lrc.lyric; Translated = $tl }
    } catch { }
    return $null
}

function Get-AudioDuration {
    param([string]$Path)
    try {
        $d = & $FFprobe -v error -show_entries format=duration -of csv=p=0 $Path 2>$null
        if ($d) { return [double]$d }
    } catch { }
    return 0
}

function Normalize-Text {
    param([string]$t)
    if (-not $t) { return '' }
    return ($t.ToLower() -replace '[\s\p{P}\p{S}]', '')
}

# 打分：越小越好。时长差为主，名称不含关键词则重罚
function Get-Score {
    param($Song, [double]$LocalDur, [string]$Keyword, [string]$FileName, [string]$ExpectedArtist = '')
    $cDur = $Song.duration / 1000
    $durDiff = [math]::Abs($cDur - $LocalDur)
    $score = $durDiff

    $nName = Normalize-Text $Song.name
    $nKw   = Normalize-Text $Keyword
    $nFile = Normalize-Text $FileName

    # 歌名与关键词互相包含 -> 强奖励
    if ($nKw -and $nName) {
        if ($nName -eq $nKw) { $score -= 30 }
        elseif ($nFile.Contains($nName) -or $nName.Contains($nKw) -or $nKw.Contains($nName)) { $score -= 15 }
        else { $score += 40 }
    }

    # 艺术家出现在文件名里 -> 奖励
    foreach ($a in $Song.artists) {
        if ($nFile.Contains((Normalize-Text $a.name))) { $score -= 20; break }
    }

    if ($ExpectedArtist) {
        $expectedArtistKey = Normalize-Text $ExpectedArtist
        $candidateArtists = @($Song.artists | ForEach-Object { Normalize-Text $_.name } | Where-Object { $_ })
        $artistMatch = $candidateArtists | Where-Object {
            $_ -eq $expectedArtistKey -or $_.Contains($expectedArtistKey) -or $expectedArtistKey.Contains($_)
        } | Select-Object -First 1
        if ($artistMatch) { $score -= 35 } else { $score += 35 }
    }

    return $score
}

function Test-LyricTitleMatch {
    param($Song, [string]$Keyword)
    $songName = Normalize-Text $Song.name
    $queryName = Normalize-Text $Keyword
    if (-not $songName -or -not $queryName) { return $false }
    return $songName -eq $queryName -or $songName.Contains($queryName) -or $queryName.Contains($songName)
}

function Get-ReliableArtist {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $clean = $Value.Trim()
    if ($clean.Length -gt 24 -or $clean -match '[“”"「」『』《》。，！？|]') { return '' }
    return $clean
}

# ---------- 主流程 ----------
$files = Get-ChildItem $MusicDir -Filter *.mp3 | Where-Object { $_.Name -like $Filter } | Sort-Object Name
if ($Limit -gt 0) { $files = $files | Select-Object -First $Limit }

$results = @()
$idx = 0
$stat = @{ ok = 0; noLyric = 0; noMatch = 0; skipped = 0; suspect = 0 }

foreach ($f in $files) {
    $idx++
    $lrcPath = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')

    if ((Test-Path $lrcPath) -and -not $Force) {
        $stat.skipped++
        continue
    }

    $parsed = Get-Candidates $f.BaseName
    $localDur = Get-AudioDuration $f.FullName

    Write-Host ("[{0}/{1}] {2}" -f $idx, $files.Count, $f.BaseName) -ForegroundColor DarkGray

    # 收集所有候选并打分，供后续按序回退
    $pool = @{}
    $tried = 0

    foreach ($kw in $parsed.Candidates) {
        if ($tried -ge 3) { break }
        $tried++

        # 带艺术家一起搜，命中率更高
        $queryList = @()
        if ($parsed.Artist) { $queryList += "$kw $($parsed.Artist)" }
        $queryList += $kw

        foreach ($qs in $queryList) {
            $songs = Search-NetEase -Keyword $qs -Cnt 5
            Start-Sleep -Milliseconds 350
            if ($songs.Count -eq 0) { continue }

            foreach ($sg in $songs) {
                $sc = Get-Score -Song $sg -LocalDur $localDur -Keyword $kw -FileName $f.BaseName -ExpectedArtist (Get-ReliableArtist $parsed.Artist)
                $k = [string]$sg.id
                if ((-not $pool.ContainsKey($k)) -or ($sc -lt $pool[$k].Score)) {
                    $pool[$k] = [PSCustomObject]@{ Song = $sg; Score = $sc; Kw = $kw }
                }
            }
        }
        $curBest = ($pool.Values | Sort-Object Score | Select-Object -First 1)
        if ($curBest -and $curBest.Score -lt -20) { break }
    }

    $ranked = @($pool.Values | Sort-Object Score)
    $best = if ($ranked.Count -gt 0) { $ranked[0].Song } else { $null }
    $bestScore = if ($ranked.Count -gt 0) { $ranked[0].Score } else { [double]::MaxValue }
    $bestKw = if ($ranked.Count -gt 0) { $ranked[0].Kw } else { '' }

    if (-not $best) {
        Write-Host "      -> 无搜索结果" -ForegroundColor Red
        $stat.noMatch++
        $results += [PSCustomObject]@{
            File=$f.Name; UsedQuery=''; Matched=''; MatchedArtist=''
            LocalDur=[int]$localDur; MatchDur=0; Score=''; Status='NO_MATCH'
        }
        continue
    }

    $matchArtist = ($best.artists | ForEach-Object { $_.name }) -join ','
    $durDiff = [math]::Abs($best.duration/1000 - $localDur)
    $status = if ($bestScore -le 0 -and $durDiff -le 25) { 'OK' } else { 'SUSPECT' }

    $color = if ($status -eq 'OK') { 'Green' } else { 'Yellow' }
    Write-Host ("      查询[{0}] -> {1} - {2} ({3}s vs {4}s, score {5}) [{6}]" -f `
        $bestKw, $matchArtist, $best.name, [int]$localDur, [int]($best.duration/1000), [int]$bestScore, $status) -ForegroundColor $color

    # 取歌词：最佳匹配无词时，按分数回退到下一个候选（同名不同版本常有词）
    $lyr = $null; $lyricFrom = $best; $lyricMatch = $null
    $probe = 0
    foreach ($cand in $ranked) {
        if ($probe -ge 4) { break }
        $probe++
        if (-not (Test-LyricTitleMatch -Song $cand.Song -Keyword $cand.Kw)) {
            continue
        }
        $try = Get-NetEaseLyric -SongId $cand.Song.id
        Start-Sleep -Milliseconds 300
        if ($try -and $try.Lrc -and ($try.Lrc -match '\[\d+:')) {
            $lyr = $try; $lyricFrom = $cand.Song; $lyricMatch = $cand
            if ($cand.Song.id -ne $best.id) {
                Write-Host ("      -> 回退取词自: {0} - {1}" -f (($cand.Song.artists | ForEach-Object { $_.name }) -join ','), $cand.Song.name) -ForegroundColor DarkCyan
            }
            break
        }
    }
    $hasLyric = $null -ne $lyr

    if (-not $hasLyric) {
        Write-Host "      -> 无歌词(纯音乐?)" -ForegroundColor DarkYellow
        $stat.noLyric++
        $status = 'NO_LYRIC'
    } else {
        $lyricDurDiff = [math]::Abs($lyricFrom.duration / 1000 - $localDur)
        $lyricScore = [double]$lyricMatch.Score
        $status = if ($lyricScore -le 0 -and $lyricDurDiff -le 25) { 'OK' } else { 'SUSPECT' }
        if (-not $DryRun -and $status -eq 'OK') {
            $content = $lyr.Lrc
            if ($lyr.Translated -and ($lyr.Translated -match '\[\d+:')) {
                $content = $content.TrimEnd() + "`n" + $lyr.Translated
            }
            [System.IO.File]::WriteAllText($lrcPath, $content, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "      -> 已写入 .lrc" -ForegroundColor DarkGreen
        } elseif (-not $DryRun) {
            Write-Host "      -> 匹配置信度不足，跳过写入歌词" -ForegroundColor Yellow
        }
        if ($status -eq 'OK') { $stat.ok++ } else { $stat.suspect++ }
    }

    $reportSong = if ($lyricFrom) { $lyricFrom } else { $best }
    $reportScore = if ($lyricMatch) { [int]$lyricMatch.Score } else { [int]$bestScore }
    $reportDur = if ($reportSong) { [int]($reportSong.duration / 1000) } else { 0 }
    $reportArtist = if ($reportSong) { (($reportSong.artists | ForEach-Object { $_.name }) -join ',') } else { '' }

    $results += [PSCustomObject]@{
        File=$f.Name; UsedQuery=$bestKw; Matched=if ($reportSong) { $reportSong.name } else { '' }; MatchedArtist=$reportArtist
        LocalDur=[int]$localDur; MatchDur=$reportDur
        Score=$reportScore; Status=$status
    }
}

$existingResults = @()
if (Test-Path -LiteralPath $Report -PathType Leaf) {
    $existingResults = @(Import-Csv -LiteralPath $Report -ErrorAction SilentlyContinue)
}
$currentFiles = @($results | ForEach-Object { [string]$_.File })
$mergedResults = @($existingResults | Where-Object { $currentFiles -notcontains [string]$_.File }) + @($results)
$mergedResults | Sort-Object File | Export-Csv -Path $Report -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "==================== 汇总 ====================" -ForegroundColor Cyan
Write-Host ("处理:     {0}" -f $files.Count)
Write-Host ("成功:     {0}" -f $stat.ok) -ForegroundColor Green
Write-Host ("需复核:   {0}" -f $stat.suspect) -ForegroundColor Yellow
Write-Host ("无歌词:   {0}" -f $stat.noLyric) -ForegroundColor DarkYellow
Write-Host ("无匹配:   {0}" -f $stat.noMatch) -ForegroundColor Red
Write-Host ("已跳过:   {0}" -f $stat.skipped) -ForegroundColor DarkGray
Write-Host ("报告:     {0}" -f $Report) -ForegroundColor Cyan
if ($DryRun) { Write-Host "【DryRun，未写文件】" -ForegroundColor Magenta }
Write-Host "=============================================" -ForegroundColor Cyan
