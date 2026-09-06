<#
.SYNOPSIS
    手动修正个别歌曲的歌词（当自动匹配错误时用）
.DESCRIPTION
    直接指定 网易云歌曲ID -> 覆盖写入对应的 .lrc
.EXAMPLE
    .\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*若月亮还没来*" -SongId 1974443814
    # 只搜索不写入:
    .\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*若月亮还没来*" -Search "若月亮还没来"
#>
param(
    [Parameter(Mandatory=$true)][string]$FilePattern,
    [long]$SongId = 0,
    [string]$Search = ''
)

$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$MusicDir = 'E:\Project\MusicServer\Music'
$Headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
    'Referer'    = 'https://music.163.com/'
}

$f = Get-ChildItem $MusicDir -Filter "$FilePattern.mp3" | Select-Object -First 1
if (-not $f) { Write-Host "未找到文件: $FilePattern" -ForegroundColor Red; exit 1 }
Write-Host "目标文件: $($f.Name)" -ForegroundColor Cyan

if ($Search) {
    $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($Search))&type=1&limit=10"
    $r = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 20
    Write-Host "`n搜索结果 (用 -SongId 选一个):" -ForegroundColor Yellow
    foreach ($s in $r.result.songs) {
        $ly = Invoke-RestMethod "https://music.163.com/api/song/lyric?id=$($s.id)&lv=1&kv=1&tv=-1" -Headers $Headers -TimeoutSec 20
        $has = if ($ly.lrc.lyric -match '\[\d+:') { '有词' } else { '无词' }
        Write-Host ("  {0,-12} {1,-35} {2,-25} {3}s  {4}" -f $s.id, $s.name, (($s.artists | ForEach-Object { $_.name }) -join ','), [int]($s.duration/1000), $has)
        Start-Sleep -Milliseconds 250
    }
    exit 0
}

if ($SongId -eq 0) { Write-Host "请提供 -SongId 或 -Search" -ForegroundColor Red; exit 1 }

$ly = Invoke-RestMethod "https://music.163.com/api/song/lyric?id=$SongId&lv=1&kv=1&tv=-1" -Headers $Headers -TimeoutSec 20
if (-not ($ly.lrc.lyric -match '\[\d+:')) { Write-Host "该 ID 无时间轴歌词" -ForegroundColor Red; exit 1 }

$content = $ly.lrc.lyric
if ($ly.tlyric -and ($ly.tlyric.lyric -match '\[\d+:')) { $content = $content.TrimEnd() + "`n" + $ly.tlyric.lyric }

$lrcPath = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')
[System.IO.File]::WriteAllText($lrcPath, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已写入: $(Split-Path $lrcPath -Leaf)" -ForegroundColor Green
Write-Host ($content -split "`n" | Select-Object -First 5 | Out-String) -ForegroundColor DarkGray
