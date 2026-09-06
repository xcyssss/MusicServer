<#
.SYNOPSIS
    B站收藏夹批量音频下载脚本
.DESCRIPTION
    使用 yt-dlp 从 B站收藏夹批量提取音频并保存为 MP3
    下载后会自动写入标题/上传者作为 ID3 标签
.PARAMETER FavoritesUrl
    B站收藏夹 URL，例如: https://www.bilibili.com/medialist/detail/ml1234567890
    或收藏夹编号: ml1234567890
.PARAMETER CookieFile
    B站 Cookie 文件路径（用于访问需要登录的收藏夹）
.PARAMETER OutputDir
    音频输出目录，默认 E:\Project\MusicServer\Music
.EXAMPLE
    .\scripts\maintenance\download_bilibili_favorites.ps1 -FavoritesUrl "https://www.bilibili.com/medialist/detail/ml1234567890" -CookieFile "cookies.txt"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$FavoritesUrl,

    [Parameter(Mandatory=$false)]
    [string]$CookieFile = "",

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "E:\Project\MusicServer\Music"
)

# yt-dlp 可执行文件路径
$ytDlp = "C:\Users\dell\anaconda3\Scripts\yt-dlp.exe"

# 确保输出目录存在
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Write-Host "已创建输出目录: $OutputDir" -ForegroundColor Green
}

# 构建 yt-dlp 参数
$args = @(
    # 提取音频
    "--extract-audio",
    # 音频格式转为 mp3
    "--audio-format", "mp3",
    # 音频质量最高 (0=最好, 10=最差)
    "--audio-quality", "0",
    # 输出文件名格式: 标题.mp3
    "-o", "$OutputDir\%(title)s.%(ext)s",
    # 嵌入缩略图作为封面
    "--embed-thumbnail",
    # 嵌入元数据 (标题、上传者等)
    "--embed-metadata",
    # ★ 增量下载: 用 archive 文件记录已下载的视频 ID
    #   下次运行时直接跳过，不再重新获取视频信息
    "--download-archive", "$OutputDir\.downloaded.txt",
    # 跳过已下载的视频 (双重保险: archive 没记但文件已存在时)
    "--no-overwrites",
    # 继续上次中断的下载
    "--continue",
    # 限制下载并发数
    "--concurrent-fragments", "3",
    # 不显示进度条 (减少日志)
    "--no-progress",
    # 限制单个视频大小不超过 200MB (防止下载大视频)
    "--max-filesize", "200M",
    # 优先下载最低画质视频 (只需要音频，节省带宽)
    "-f", "worstaudio/worst",
    # 如果收藏夹中有不支持的内容，跳过
    "--ignore-errors"
)

# 添加 Cookie 文件
if ($CookieFile -ne "" -and (Test-Path $CookieFile)) {
    $args += @("--cookies", $CookieFile)
    Write-Host "使用 Cookie 文件: $CookieFile" -ForegroundColor Yellow
} else {
    Write-Host "警告: 未提供 Cookie 文件，只能下载公开收藏夹" -ForegroundColor Yellow
    Write-Host "      会员视频或私密收藏夹将无法下载" -ForegroundColor Yellow
}

# 添加收藏夹 URL
$args += $FavoritesUrl

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  B站收藏夹音频下载" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "收藏夹: $FavoritesUrl"
Write-Host "输出到: $OutputDir"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 执行下载
& $ytDlp @args

# 统计下载结果
$mp3Files = Get-ChildItem $OutputDir -Filter "*.mp3" -ErrorAction SilentlyContinue
$archiveFile = Join-Path $OutputDir ".downloaded.txt"
$downloadedCount = 0
if (Test-Path $archiveFile) {
    $downloadedCount = (Get-Content $archiveFile | Where-Object { $_.Trim() -ne "" }).Count
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  下载完成!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "音乐目录:   $OutputDir"
Write-Host "MP3 文件数: $($mp3Files.Count)"
Write-Host "已记录下载: $downloadedCount 首歌曲"
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "提示: 如果 Navidrome 正在运行，它会自动扫描新文件 (每6小时)。" -ForegroundColor Cyan
Write-Host "      也可手动触发: http://localhost:4533 -> 设置 -> 立即扫描" -ForegroundColor Cyan
