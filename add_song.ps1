<#
.SYNOPSIS
    B站单曲快捷下载器 - 输入视频URL即自动下载到音乐库
.DESCRIPTION
    交互式脚本，支持连续输入多个B站视频URL，逐个下载音频到 Navidrome 音乐目录
    每次下载完自动显示库中总歌曲数
#>

$ytDlp = "C:\Users\dell\anaconda3\Scripts\yt-dlp.exe"
$OutputDir = "E:\Project\MusicServer\Music"
$CookieFile = "E:\Project\MusicServer\cookies.txt"
$ArchiveFile = "$OutputDir\.downloaded.txt"

# 确保目录存在
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

function Invoke-Download {
    param([string]$Url)

    # 构建 yt-dlp 参数
    $dlArgs = @(
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", "0",
        "-o", "$OutputDir\%(title)s.%(ext)s",
        "--embed-thumbnail",
        "--embed-metadata",
        "--download-archive", $ArchiveFile,
        "--no-overwrites",
        "--concurrent-fragments", "3",
        "--no-progress",
        "-f", "worstaudio/worst",
        "--ignore-errors",
        "--no-playlist"
    )

    # 加 Cookie（如果存在）
    if (Test-Path $CookieFile) {
        $dlArgs += @("--cookies", $CookieFile)
    }

    $dlArgs += $Url

    # 执行下载
    & $ytDlp @dlArgs 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -match "Downloading|Extracting|Deleting|has already") {
            Write-Host "  $line" -ForegroundColor DarkGray
        } elseif ($line -match "\[ExtractAudio\]|Converting") {
            Write-Host "  $line" -ForegroundColor Yellow
        } elseif ($line -match "ERROR|error") {
            Write-Host "  $line" -ForegroundColor Red
        }
    }

    # 检查是否成功（看有没有新文件出现）
    return $true
}

function Show-Stats {
    $mp3Files = Get-ChildItem $OutputDir -Filter "*.mp3" -ErrorAction SilentlyContinue
    $archiveCount = 0
    if (Test-Path $ArchiveFile) {
        $archiveCount = (Get-Content $ArchiveFile | Where-Object { $_.Trim() -ne "" }).Count
    }
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  音乐库统计                      │" -ForegroundColor Cyan
    Write-Host "  │  MP3 文件: $($mp3Files.Count.ToString().PadLeft(4)) 首       │" -ForegroundColor Cyan
    Write-Host "  │  已下载:   $($archiveCount.ToString().PadLeft(4)) 首       │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────┘" -ForegroundColor Cyan
}

# ==================== 主界面 ====================

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║       🎵 B站单曲快捷下载器  🎵            ║" -ForegroundColor Magenta
Write-Host "  ╠══════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "  ║  粘贴B站视频URL即可下载到音乐库           ║" -ForegroundColor Magenta
Write-Host "  ║  支持连续输入多首，输入 q 退出            ║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# 检查 Cookie
if (Test-Path $CookieFile) {
    Write-Host "  ✅ Cookie 文件已找到" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  未找到 Cookie 文件 ($CookieFile)" -ForegroundColor Yellow
    Write-Host "      会员视频可能无法下载" -ForegroundColor Yellow
}
Write-Host ""

Show-Stats

# 主循环
while ($true) {
    Write-Host ""
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host -NoNewline "  输入B站视频URL (或 q 退出): " -ForegroundColor White
    $input = Read-Host

    # 退出
    if ($input -eq "q" -or $input -eq "Q" -or $input -eq "exit" -or $input -eq "quit") {
        Write-Host ""
        Write-Host "  再见! 🎵" -ForegroundColor Magenta
        Write-Host ""
        break
    }

    # 空输入跳过
    if ($input.Trim() -eq "") {
        continue
    }

    # 简单验证 URL
    if ($input -notmatch "bilibili\.com" -and $input -notmatch "^BV" -and $input -notmatch "^av") {
        Write-Host "  ❌ 不是有效的B站链接，请重新输入" -ForegroundColor Red
        Write-Host "     示例: https://www.bilibili.com/video/BV1xxxxxx" -ForegroundColor DarkGray
        continue
    }

    # 如果只输入了 BV 号，补全 URL
    if ($input -match "^BV") {
        $input = "https://www.bilibili.com/video/$input"
        Write-Host "  补全URL: $input" -ForegroundColor DarkGray
    }

    # 下载
    $time = Get-Date -Format "HH:mm:ss"
    Write-Host "  [$time] 开始下载..." -ForegroundColor Cyan

    $beforeCount = (Get-ChildItem $OutputDir -Filter "*.mp3" -ErrorAction SilentlyContinue).Count
    Invoke-Download -Url $input.Trim()
    $afterCount = (Get-ChildItem $OutputDir -Filter "*.mp3" -ErrorAction SilentlyContinue).Count

    if ($afterCount -gt $beforeCount) {
        # 找到新下载的文件
        $newFile = Get-ChildItem $OutputDir -Filter "*.mp3" | Sort-Object CreationTime -Descending | Select-Object -First 1
        Write-Host ""
        Write-Host "  ✅ 下载成功!" -ForegroundColor Green
        Write-Host "     歌曲: $($newFile.BaseName)" -ForegroundColor Green
        Write-Host "     大小: $([math]::Round($newFile.Length/1MB,1)) MB" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  ℹ️  该歌曲可能已存在，或下载失败" -ForegroundColor Yellow
    }

    Show-Stats
}
