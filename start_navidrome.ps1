param(
    [int]$Port = 4533,
    [string]$ServiceName = 'Navidrome',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$url = "http://localhost:$Port"

function Test-NavidromePort {
    param([int]$Port)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', $Port).Wait(800)
        $c.Close()
        return $ok
    } catch {
        return $false
    }
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($svc) {
    if ($svc.Status -ne 'Running') {
        Write-Host "服务 $ServiceName 未运行，正在启动..." -ForegroundColor Yellow
        try {
            Start-Service -Name $ServiceName
        } catch {
            Write-Host "普通权限启动失败，尝试以管理员身份启动服务..." -ForegroundColor Yellow
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden `
                -ArgumentList '-NoProfile', '-Command', "Start-Service -Name '$ServiceName'" -Wait
        }
    }
} else {
    $exe = Join-Path $PSScriptRoot 'Navidrome\bin\navidrome.exe'
    $cfg = Join-Path $PSScriptRoot 'Navidrome\navidrome.toml'
    if (-not (Test-NavidromePort -Port $Port)) {
        Write-Host "未找到服务，直接以进程方式启动 navidrome.exe ..." -ForegroundColor Yellow
        Start-Process -FilePath $exe -ArgumentList '-c', "`"$cfg`"" `
            -WorkingDirectory (Join-Path $PSScriptRoot 'Navidrome') -WindowStyle Hidden
    }
}

Write-Host "等待 $url 就绪..." -NoNewline
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    if (Test-NavidromePort -Port $Port) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
    Write-Host '.' -NoNewline
}
Write-Host ''

if ($ready) {
    Write-Host "音乐服务器已就绪: $url" -ForegroundColor Green
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1).IPAddress
    if ($ip) { Write-Host "局域网访问: http://${ip}:$Port" -ForegroundColor Cyan }
    if (-not $NoBrowser) { Start-Process $url }
} else {
    Write-Host "启动超时，请检查日志: $(Join-Path $PSScriptRoot 'Navidrome\navidrome.log')" -ForegroundColor Red
    Read-Host '按回车退出'
}
