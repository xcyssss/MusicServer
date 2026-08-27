<#
.SYNOPSIS
    共用的 m3u 播放列表写入函数
.DESCRIPTION
    Navidrome 开启 AutoImportPlaylists 后会自动把音乐目录下的 .m3u 导入成播放列表。
    约定：
      - 路径写成相对于 m3u 文件所在目录的相对路径
      - UTF-8 无 BOM
      - 用 #PLAYLIST 指定在 Navidrome 里显示的名字
#>

function Get-RelativePathCompat {
    param([string]$BaseDir, [string]$FullPath)
    # PowerShell 5.1 (.NET Framework) 没有 Path.GetRelativePath，用 Uri 计算
    $b = $BaseDir.TrimEnd('\', '/') + '\'
    $bu = New-Object System.Uri($b)
    $fu = New-Object System.Uri($FullPath)
    $rel = $bu.MakeRelativeUri($fu).ToString()
    return [System.Uri]::UnescapeDataString($rel).Replace('/', '\')
}

function Write-M3u {
    param(
        [Parameter(Mandatory)][string]$Path,        # m3u 输出路径
        [Parameter(Mandatory)][string]$Name,        # Navidrome 中显示的播放列表名
        [AllowEmptyCollection()][array]$Tracks,     # @{ File=绝对路径; Title=; Artist=; Duration= }
        [string]$Comment
    )

    $baseDir = Split-Path -Parent $Path
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('#EXTM3U')
    [void]$sb.AppendLine("#PLAYLIST:$Name")
    if ($Comment) { [void]$sb.AppendLine("# $Comment") }

    $n = 0
    foreach ($t in $Tracks) {
        if (-not $t.File -or -not (Test-Path -LiteralPath $t.File)) { continue }

        $dur = 0
        if ($t.Duration) { $dur = [int]$t.Duration }

        $artist = if ($t.Artist) { ($t.Artist -split ',')[0] } else { '' }
        $title  = if ($t.Title) { $t.Title } else { [System.IO.Path]::GetFileNameWithoutExtension($t.File) }
        $label  = if ($artist) { "$artist - $title" } else { $title }

        $rel = Get-RelativePathCompat -BaseDir $baseDir -FullPath $t.File

        [void]$sb.AppendLine("#EXTINF:$dur,$label")
        [void]$sb.AppendLine($rel)
        $n++
    }

    if ($n -eq 0) {
        # 空列表就删掉文件，避免 Navidrome 里留一个空播放列表
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -EA SilentlyContinue }
        return 0
    }

    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $n
}
