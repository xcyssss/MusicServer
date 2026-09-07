Set-StrictMode -Version 2.0

function Resolve-MusicServerMaintenanceContext {
    param([string]$MusicDir = '')

    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    Import-Module (Join-Path $repoRoot 'MusicServer.Core.psm1') -Force
    Import-Module (Join-Path $repoRoot 'MusicServer.Database.psm1') -Force
    Import-Module (Join-Path $repoRoot 'MusicServer.State.psm1') -Force

    $config = New-MusicServerConfig -Root $repoRoot
    $effective = ''
    if (-not [string]::IsNullOrWhiteSpace($MusicDir)) {
        $effective = [IO.Path]::GetFullPath($MusicDir)
    } else {
        $envDir = [Environment]::GetEnvironmentVariable('MUSICSERVER_MUSIC_DIR')
        if (-not [string]::IsNullOrWhiteSpace($envDir)) {
            $effective = [IO.Path]::GetFullPath($envDir)
        } else {
            $dbPath = Join-Path $config.StateDir 'musicserver.db'
            if (Test-Path -LiteralPath $dbPath -PathType Leaf) {
                try {
                    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $config.Sqlite
                    Initialize-MusicServerSchema
                    $effective = Resolve-ConfiguredMusicDir -Config $config
                } catch {
                    Write-Warning "Unable to read configured music library; using the default path. $($_.Exception.Message)"
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($effective)) {
        $effective = Get-DefaultMusicDir -Root $config.Root
    }
    $config.MusicDir = [IO.Path]::GetFullPath($effective)
    $config.DailyDir = Join-Path $config.MusicDir 'DailyMix'

    return [pscustomobject]@{
        Root = $repoRoot
        Config = $config
        MusicDir = $config.MusicDir
        StateDb = Join-Path $config.StateDir 'musicserver.db'
    }
}