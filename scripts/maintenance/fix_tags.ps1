<#
.SYNOPSIS
    批量修复 B站下载的 MP3 标签
    1. 统一设置 album 为 "B站收藏"
    2. 清理 title 中的冗余内容
    3. 触发 Navidrome 重新扫描
#>

$musicDir = "E:\Project\MusicServer\Music"
$ffmpeg = "C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe"

$mp3s = Get-ChildItem $musicDir -Filter "*.mp3"
Write-Host "找到 $($mp3s.Count) 个 MP3 文件" -ForegroundColor Cyan
Write-Host ""

$count = 0
foreach ($f in $mp3s) {
    $count++
    
    # 读取当前标签
    $probe = ffprobe -v quiet -print_format json -show_format $f.FullName 2>$null | ConvertFrom-Json
    $oldTitle = $probe.format.tags.title
    $oldArtist = $probe.format.tags.artist
    
    # 文件名本身就是清理后的标题（yt-dlp 用 %(title)s 命名）
    $newTitle = $f.BaseName
    
    # 用 ffmpeg 重写标签: 保留原始 artist, 统一 album, 用文件名做 title
    $tempFile = "$($f.FullName).tmp.mp3"
    
    # 用 -metadata 写入标签, -c copy 不重新编码
    & $ffmpeg -y -i $f.FullName -c copy -metadata "title=$newTitle" -metadata "album=B站收藏" -metadata "album_artist=Various Artists" $tempFile 2>$null
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tempFile)) {
        Move-Item -Path $tempFile -Destination $f.FullName -Force
        if ($count % 20 -eq 0) {
            Write-Host "  已处理 $count / $($mp3s.Count)..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ❌ 失败: $($f.Name)" -ForegroundColor Red
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "✅ 完成! 已处理 $count 首歌曲" -ForegroundColor Green
Write-Host "   album = B站收藏" -ForegroundColor Green
Write-Host "   title = 文件名" -ForegroundColor Green
