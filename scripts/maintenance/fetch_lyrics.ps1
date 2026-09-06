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
$StateDb  = 'E:\Project\MusicServer\DailyMix_data\state\musicserver.db'
$Sqlite   = 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe'
if (-not (Test-Path -LiteralPath $Sqlite)) { $Sqlite = 'sqlite3' }
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

    # 提取可能的艺术家：优先第一个书名号之前的内容
    $artist = ''
    if ($s -match '^([^《「『]{1,20})[《「『]') {
        $artist = ($Matches[1] -split '[&,，、/／]')[0].Trim()
    } elseif ($s -match '(.+?)\s*[-–—]\s*(.+)$') {
        # "歌名 - 艺术家" 格式：破折号右侧常是艺术家（歌手/UP主），左侧是歌名。
        # 先剥离方括号/噪声词杂质（如"百万级装备试听【Hi-Res】"），再取艺术家。
        $rightSide = $Matches[2].Trim()
        $rightSide = $rightSide -replace '【[^】]*】', ' '
        $rightSide = $rightSide -replace '\[[^\]]*\]', ' '
        foreach ($w in $NoiseWords) { $rightSide = $rightSide -replace [regex]::Escape($w), ' ' }
        $rightSide = ($rightSide -replace '\s+', ' ').Trim()
        if ($rightSide -and $rightSide.Length -le 24 -and $rightSide -notmatch '[《「『」』]|EP|OST|MV|Official|FULL|翻唱|Live') {
            $artist = ($rightSide -split '[&,，、/／]')[0].Trim()
        }
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

# 打分：越小越好。时长差为主，名称不含关键词则重罚。
# 关键改进：把时长惩罚按"名称/艺术家信任度"缩放。本地多为 B 站完整版/Live，
# 时长和网易云原版常有差异，只要歌名+艺术家对得上就不应因时长差判错配。
function Get-Score {
    param($Song, [double]$LocalDur, [string]$Keyword, [string]$FileName, [string]$ExpectedArtist = '')
    $cDur = $Song.duration / 1000
    $durDiff = [math]::Abs($cDur - $LocalDur)

    $nName = Normalize-Text $Song.name
    $nKw   = Normalize-Text $Keyword
    $nFile = Normalize-Text $FileName

    # 名称信任度：歌名与关键词是否对上（-30 强、-15 中、+40 无）
    $nameTrust = 0
    if ($nKw -and $nName) {
        if ($nName -eq $nKw) { $nameTrust -= 30 }
        elseif ($nFile.Contains($nName) -or $nName.Contains($nKw) -or $nKw.Contains($nName)) { $nameTrust -= 15 }
        else { $nameTrust += 40 }
    }

    # 艺术家信任度
    $artistTrust = 0
    foreach ($a in $Song.artists) {
        if ($nFile.Contains((Normalize-Text $a.name))) { $artistTrust -= 20; break }
    }
    if ($ExpectedArtist) {
        $expectedArtistKey = Normalize-Text $ExpectedArtist
        $candidateArtists = @($Song.artists | ForEach-Object { Normalize-Text $_.name } | Where-Object { $_ })
        $artistMatch = $candidateArtists | Where-Object {
            $_ -eq $expectedArtistKey -or $_.Contains($expectedArtistKey) -or $expectedArtistKey.Contains($_)
        } | Select-Object -First 1
        if ($artistMatch) { $artistTrust -= 35 } else { $artistTrust += 35 }
    }

    # 名称或艺术家强匹配（信任度足够负）时，时长差不再当作错配证据，
    # 而是打一个更温和的折扣；名称/艺术家都不确定时，时长仍是主要依据。
    if ($nameTrust -le -15 -or $artistTrust -le -20) {
        $score = $nameTrust + $artistTrust - 5 * [math]::Min($durDiff, 20)
    } else {
        $score = $durDiff + $nameTrust + $artistTrust
    }

    return $score
}

# 统一置信度判定：OK 必须名称强匹配（score 显著为负）。时长大时，还要求
# 艺术家能确认匹配，否则仍判 SUSPECT —— 这样 B 站完整版（歌名+艺术家都对、
# 只是版本时长不同）能通过，而"只对上歌名、艺术家对不上"（翻唱/同名不同歌手）
# 保持 SUSPECT。返回 'OK' 或 'SUSPECT'。
function Test-ConfidentMatch {
    param([double]$Score, [double]$DurDiff, [bool]$ArtistConfirmed)
    $nameIsStrong = ($Score -le -25)
    if ($nameIsStrong -and ($DurDiff -le 25 -or $ArtistConfirmed)) { return 'OK' }
    return 'SUSPECT'
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

# ---------- canonical 权威音源优先 ----------
# canonical_tracks 记录了每日推荐/下载时经网易云 API 确认过的准确 song id。
# 若本地文件能匹配到 canonical（干净标题 + 时长接近），直接用其 netease_id
# 抓词，避免按文件名盲搜时命中同名但不同的歌（时间轴错位的根源）。
$script:CanonicalMap = $null
function Load-CanonicalMap {
    if ($null -ne $script:CanonicalMap) { return }
    $script:CanonicalMap = @{}
    if (-not (Test-Path -LiteralPath $StateDb)) { return }
    try {
        # sqlite 管道输出：quote() 包裹 + tab 分隔，避免 | / 编码 / 引号转义问题
        $lines = & $Sqlite $StateDb ".mode list" ".separator '`t'" "SELECT quote(title), quote(artist), duration, identifiers_json FROM canonical_tracks WHERE identifiers_json LIKE '%netease%';" 2>$null
        foreach ($line in @($lines)) {
            if (-not $line) { continue }
            $cols = $line -split "`t"
            if ($cols.Count -lt 4) { continue }
            $title = $cols[0].Trim()
            $artist = $cols[1].Trim()
            if ($title.Length -ge 2 -and $title.StartsWith("'")) { $title = $title.Substring(1, $title.Length - 2) }
            if ($artist.Length -ge 2 -and $artist.StartsWith("'")) { $artist = $artist.Substring(1, $artist.Length - 2) }
            $dur = 0; [void][int]::TryParse($cols[2].Trim(), [ref]$dur)
            $nid = ''
            if ($cols[3] -match '"type"\s*:\s*"netease"\s*,\s*"value"\s*:\s*"(\d+)"') { $nid = $Matches[1] }
            if (-not $nid) { continue }
            $key = Normalize-Text $title
            if (-not $key) { continue }
            $script:CanonicalMap[$key] = [pscustomobject]@{
                Title = $title; Artist = $artist
                Duration = $dur; NeteaseId = $nid
            }
        }
    } catch {}
}

# 从本地文件名+时长找 canonical 权威匹配。返回匹配对象或 $null。
# 匹配规则：文件名的候选标题（书名号/破折号后的片段）规范化后等于
# canonical.title，且时长差 <= 允许漂移（版本差异容忍到 40s）。
function Find-CanonicalMatch {
    param([string]$FileName, [double]$LocalDur)
    Load-CanonicalMap
    if ($script:CanonicalMap.Count -eq 0) { return $null }
    $parsedC = Get-Candidates $FileName
    $titleKeys = @()
    $hasPart = $FileName -match '\sp\d{2}\s+'
    if ($hasPart) {
        # 分 P 文件：只信 pXX 后的具体歌名（合集标题含多首歌，不可作匹配依据）
        $m = $FileName -match '\sp\d{2}\s+([^|｜（(【\[]+)'
        if ($m) {
            $k = Normalize-Text $Matches[1].Trim()
            if ($k -and $k.Length -ge 2) { $titleKeys = @($k) }
        }
    } else {
        foreach ($c in $parsedC.Candidates) {
            $k = Normalize-Text $c
            if (-not $k -or $k.Length -lt 2) { continue }
            # 跳过整串文件名候选（含多个书名号/分隔符的合集标题），避免误配
            if ($k -match '[《「『]' -or $c -match '^.{25,}$') { continue }
            $titleKeys += $k
        }
    }
    foreach ($tk in ($titleKeys | Select-Object -Unique)) {
        if ($script:CanonicalMap.ContainsKey($tk)) {
            $cm = $script:CanonicalMap[$tk]
            $allowed = if ($cm.Duration -gt 0) { [Math]::Max(25, [Math]::Min(40, [int]($cm.Duration * 0.12))) } else { 40 }
            if ([math]::Abs($cm.Duration - $LocalDur) -le $allowed) { return $cm }
        }
    }
    return $null
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

    # ---- Canonical 权威优先：本地文件匹配到 canonical 的准确网易云 ID ----
    $canonical = Find-CanonicalMatch -FileName $f.BaseName -LocalDur $localDur
    if ($canonical) {
        $lrcPathC = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')
        $tryC = Get-NetEaseLyric -SongId $canonical.NeteaseId
        Start-Sleep -Milliseconds 300
        if ($tryC -and $tryC.Lrc -and ($tryC.Lrc -match '\[\d+:')) {
            $durDiffC = [math]::Abs($canonical.Duration - $localDur)
            $contentC = $tryC.Lrc
            if ($tryC.Translated -and ($tryC.Translated -match '\[\d+:')) {
                $contentC = $contentC.TrimEnd() + "`n" + $tryC.Translated
            }
            $statusC = if ($durDiffC -le 40) { 'OK' } else { 'SUSPECT' }
            if (-not $DryRun -and $statusC -eq 'OK') {
                [System.IO.File]::WriteAllText($lrcPathC, $contentC, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host ("      权威ID[{0}] -> {1} - {2} (canonical {3}s vs 本地 {4}s) [OK] 已写入" -f $canonical.NeteaseId, $canonical.Artist, $canonical.Title, [int]$canonical.Duration, [int]$localDur) -ForegroundColor Green
            } elseif (-not $DryRun) {
                Write-Host ("      权威ID[{0}] 时长差过大({1}s) 跳过写入" -f $canonical.NeteaseId, [math]::Round($durDiffC,1)) -ForegroundColor Yellow
            } else {
                Write-Host ("      权威ID[{0}] -> {1} - {2} (canonical {3}s vs 本地 {4}s) [{5}]" -f $canonical.NeteaseId, $canonical.Artist, $canonical.Title, [int]$canonical.Duration, [int]$localDur, $statusC) -ForegroundColor Green
            }
            if ($statusC -eq 'OK') { $stat.ok++ } else { $stat.suspect++ }
            $results += [pscustomObject]@{
                File=$f.Name; UsedQuery="canonical:$($canonical.NeteaseId)"; Matched=$canonical.Title
                MatchedArtist=$canonical.Artist; LocalDur=[int]$localDur; MatchDur=$canonical.Duration
                Score=0; Status=$statusC
            }
            continue
        } else {
            Write-Host ("      权威ID[{0}] 无歌词，退回搜索" -f $canonical.NeteaseId) -ForegroundColor DarkYellow
        }
    }

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
    # 判定 OK 必须名称强匹配（score 显著为负）。时长大时，还要求艺术家能确认
    # 匹配，否则仍判 SUSPECT —— 这样 B 站完整版（歌名+艺术家都对、只是时长不同）
    # 能通过，而"只对上歌名、艺术家对不上"（如翻唱/不同歌手的同名歌）保持 SUSPECT。
    $artistConfirmed = $false
    if ($parsed.Artist) {
        $expArtist = (Get-ReliableArtist $parsed.Artist)
        if ($expArtist) {
            $expKey = Normalize-Text $expArtist
            foreach ($a in @($best.artists)) {
                $ak = Normalize-Text $a.name
                if ($ak -and ($ak -eq $expKey -or $ak.Contains($expKey) -or $expKey.Contains($ak))) { $artistConfirmed = $true; break }
            }
        }
    }
    # 无清晰艺术家时，只能用时长短来证明可信
    $status = Test-ConfidentMatch -Score $bestScore -DurDiff $durDiff -ArtistConfirmed $artistConfirmed

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
        # 用统一置信度判定；为回退候选单独算艺术家确认。
        $lyricArtistConfirmed = $false
        if ($parsed.Artist) {
            $expArtist = (Get-ReliableArtist $parsed.Artist)
            if ($expArtist) {
                $expKey = Normalize-Text $expArtist
                foreach ($a in @($lyricMatch.Song.artists)) {
                    $ak = Normalize-Text $a.name
                    if ($ak -and ($ak -eq $expKey -or $ak.Contains($expKey) -or $expKey.Contains($ak))) { $lyricArtistConfirmed = $true; break }
                }
            }
        }
        $status = Test-ConfidentMatch -Score $lyricScore -DurDiff $lyricDurDiff -ArtistConfirmed $lyricArtistConfirmed
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
