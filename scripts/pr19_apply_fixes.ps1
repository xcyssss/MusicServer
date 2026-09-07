$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Read-RepoText {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-RepoText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $withBom = $ext -in @('.ps1', '.psm1')
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($withBom)))
}

function Replace-LiteralOnce {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New,
        [Parameter(Mandatory)][string]$Label
    )
    $text = Read-RepoText $Path
    $index = $text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw "$Label: pattern not found in $Path" }
    $updated = $text.Substring(0, $index) + $New + $text.Substring($index + $Old.Length)
    Write-RepoText -Path $Path -Text $updated
}

function Replace-RegexOnce {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Label
    )
    $text = Read-RepoText $Path
    $options = [Text.RegularExpressions.RegexOptions]::Singleline -bor [Text.RegularExpressions.RegexOptions]::Multiline
    $regex = New-Object Text.RegularExpressions.Regex($Pattern, $options)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) { throw "$Label: expected 1 match in $Path, found $($matches.Count)" }
    $updated = $regex.Replace($text, [Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement }, 1)
    Write-RepoText -Path $Path -Text $updated
}

function Ensure-LiteralAfter {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Anchor,
        [Parameter(Mandatory)][string]$Insertion,
        [Parameter(Mandatory)][string]$Sentinel,
        [Parameter(Mandatory)][string]$Label
    )
    $text = Read-RepoText $Path
    if ($text.Contains($Sentinel)) { return }
    $index = $text.IndexOf($Anchor, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw "$Label: anchor not found in $Path" }
    $index += $Anchor.Length
    $updated = $text.Substring(0, $index) + $Insertion + $text.Substring($index)
    Write-RepoText -Path $Path -Text $updated
}

Write-Host 'Patch 1/9: split state and library initialization'
$coreReplacement = @'
function Initialize-MusicServerState {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [switch]$SkipLibrary
    )

    $paths = @($Config.DataDir, $Config.StateDir)
    if (-not $SkipLibrary) { $paths += @($Config.MusicDir, $Config.DailyDir) }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
    }
}

function Initialize-MusicServerLibrary {
    param([Parameter(Mandatory)][psobject]$Config)

    $defaultDir = Get-DefaultMusicDir -Root $Config.Root
    $effective = [IO.Path]::GetFullPath([string]$Config.MusicDir)
    $isDefault = ($effective -eq [IO.Path]::GetFullPath($defaultDir))

    # A configured removable/offline library must stay unavailable. Do not
    # silently recreate or fall back to the default library on startup.
    if (-not (Test-Path -LiteralPath $effective -PathType Container)) {
        if (-not $isDefault) { return $false }
        New-Item -ItemType Directory -Force -Path $effective | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Config.DailyDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Config.DailyDir | Out-Null
    }
    return $true
}
'@
Replace-RegexOnce -Path 'MusicServer.Core.psm1' -Pattern '^function Initialize-MusicServerState \{.*?^\}\r?\n' -Replacement ($coreReplacement + "`r`n") -Label 'core initialization split'

Write-Host 'Patch 2/9: fix runtime initialization order'
foreach ($path in @('music_api.ps1','wanted_worker.ps1','daily_cleanup.ps1')) {
    Replace-LiteralOnce -Path $path -Old 'Initialize-MusicServerState -Config $Config' -New 'Initialize-MusicServerState -Config $Config -SkipLibrary' -Label "skip library before DB in $path"
    Ensure-LiteralAfter -Path $path -Anchor 'Apply-ConfiguredMusicDir -Config $Config' -Insertion "`r`nInitialize-MusicServerLibrary -Config `$Config | Out-Null" -Sentinel 'Initialize-MusicServerLibrary -Config $Config | Out-Null' -Label "initialize effective library in $path"
}

$dailyTop = @'
$Config = New-MusicServerConfig -Root $Root
$dbPath = Join-Path $Config.StateDir 'musicserver.db'
if ($DryRun) {
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        throw "DryRun requires an existing SQLite database: $dbPath"
    }
    Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
} else {
    Initialize-MusicServerState -Config $Config -SkipLibrary
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
    Initialize-MusicServerSchema
}
Apply-ConfiguredMusicDir -Config $Config
if (-not $DryRun) { Initialize-MusicServerLibrary -Config $Config | Out-Null }

'@
Replace-RegexOnce -Path 'daily_recommend.ps1' -Pattern '\$Config = New-MusicServerConfig -Root \$Root\r?\n\$dbPath = Join-Path \$Config\.StateDir ''musicserver\.db''\r?\nif \(\$DryRun\) \{.*?\r?\n\}\r?\n\r?\n# Legacy import' -Replacement ($dailyTop + '# Legacy import') -Label 'daily recommend configured dir for dry/non-dry'

Ensure-LiteralAfter -Path 'start_musicserver_ui.ps1' -Anchor '} catch {}' -Insertion "`r`ntry { Initialize-MusicServerLibrary -Config `$Config | Out-Null } catch {}" -Sentinel 'Initialize-MusicServerLibrary -Config $Config | Out-Null' -Label 'UI effective library init'

Write-Host 'Patch 3/9: harden Navidrome TOML path sync'
$navSync = @'
function Sync-NavidromeMusicFolder {
    <#
    .SYNOPSIS
      Updates navidrome.toml MusicFolder to match the effective MusicDir.
      Writes a TOML basic string with escaped Windows backslashes and quotes.
    #>
    param(
        [Parameter(Mandatory)][string]$NdConfigPath,
        [Parameter(Mandatory)][string]$NewMusicFolder
    )
    if (-not (Test-Path -LiteralPath $NdConfigPath -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $NdConfigPath -Raw -Encoding UTF8
    $encoded = $NewMusicFolder.Replace('\', '\\').Replace('"', '\"')
    $desiredLine = 'MusicFolder = "' + $encoded + '"'
    $pattern = '(?m)^\s*MusicFolder\s*=.*$'

    if ([regex]::IsMatch($content, $pattern)) {
        $currentLine = [regex]::Match($content, $pattern).Value.Trim()
        if ($currentLine -eq $desiredLine) { return $false }
        $updated = [regex]::Replace(
            $content,
            $pattern,
            [Text.RegularExpressions.MatchEvaluator]{ param($m) $desiredLine },
            1
        )
    } else {
        $updated = $desiredLine + [Environment]::NewLine + $content
    }

    [IO.File]::WriteAllText($NdConfigPath, $updated, (New-Object Text.UTF8Encoding($false)))
    return $true
}
'@
Replace-RegexOnce -Path 'MusicServer.State.psm1' -Pattern '^function Sync-NavidromeMusicFolder \{.*?^\}\r?\n\r?\nExport-ModuleMember -Function \*' -Replacement ($navSync + "`r`nExport-ModuleMember -Function *") -Label 'Navidrome sync function'

Write-Host 'Patch 4/9: add maintenance MusicDir resolver'
$maintenanceHelper = @'
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
'@
Write-RepoText -Path 'scripts/maintenance/MusicServer.Maintenance.ps1' -Text $maintenanceHelper

$fetch = Read-RepoText 'scripts/maintenance/fetch_lyrics.ps1'
$fetch = $fetch.Replace("    [string]`$Filter = '*'`r`n)", "    [string]`$Filter = '*',`r`n    [string]`$MusicDir = ''`r`n)")
$fetch = [regex]::Replace($fetch, "(?ms)^\$MusicDir = 'E:\\\\Project\\\\MusicServer\\\\Music'\r?\n\$FFprobe\s+=.*?\r?\n\$Report\s+=.*?\r?\n\$StateDb\s+=.*?\r?\n\$Sqlite\s+=.*?\r?\nif \(-not \(Test-Path -LiteralPath \$Sqlite\)\) \{ \$Sqlite = 'sqlite3' \}\r?\n", @'
. (Join-Path $PSScriptRoot 'MusicServer.Maintenance.ps1')
$Maintenance = Resolve-MusicServerMaintenanceContext -MusicDir $MusicDir
$MusicDir = $Maintenance.MusicDir
$FFprobe = $Maintenance.Config.FFprobe
$Report = Join-Path $Maintenance.Root 'lyrics_report.csv'
$StateDb = $Maintenance.StateDb
$Sqlite = $Maintenance.Config.Sqlite
'@ + "`r`n", 1)
if ($fetch -notmatch 'Resolve-MusicServerMaintenanceContext') { throw 'fetch_lyrics maintenance resolver patch failed' }
Write-RepoText 'scripts/maintenance/fetch_lyrics.ps1' $fetch

$one = Read-RepoText 'scripts/maintenance/fix_one_lyric.ps1'
$one = $one.Replace("    [string]`$Search = ''`r`n)", "    [string]`$Search = '',`r`n    [string]`$MusicDir = ''`r`n)")
$one = $one.Replace("`$MusicDir = 'E:\Project\MusicServer\Music'", ". (Join-Path `$PSScriptRoot 'MusicServer.Maintenance.ps1')`r`n`$Maintenance = Resolve-MusicServerMaintenanceContext -MusicDir `$MusicDir`r`n`$MusicDir = `$Maintenance.MusicDir")
if ($one -notmatch 'Resolve-MusicServerMaintenanceContext') { throw 'fix_one_lyric maintenance resolver patch failed' }
Write-RepoText 'scripts/maintenance/fix_one_lyric.ps1' $one

$tags = Read-RepoText 'scripts/maintenance/fix_tags.ps1'
$tags = $tags.Replace("`$musicDir = \"E:\Project\MusicServer\Music\"`r`n`$ffmpeg = \"C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe\"", @'
param([string]$MusicDir = '')

. (Join-Path $PSScriptRoot 'MusicServer.Maintenance.ps1')
$Maintenance = Resolve-MusicServerMaintenanceContext -MusicDir $MusicDir
$MusicDir = $Maintenance.MusicDir
$ffmpeg = $Maintenance.Config.FFmpeg
'@)
if ($tags -notmatch 'Resolve-MusicServerMaintenanceContext') { throw 'fix_tags maintenance resolver patch failed' }
Write-RepoText 'scripts/maintenance/fix_tags.ps1' $tags

$add = Read-RepoText 'scripts/maintenance/add_song.ps1'
$add = $add.Replace("#>`r`n`r`n`$ytDlp = \"C:\Users\dell\anaconda3\Scripts\yt-dlp.exe\"`r`n`$OutputDir = \"E:\Project\MusicServer\Music\"`r`n`$CookieFile = \"E:\Project\MusicServer\cookies.txt\"", @'
#>
param([string]$MusicDir = '')

. (Join-Path $PSScriptRoot 'MusicServer.Maintenance.ps1')
$Maintenance = Resolve-MusicServerMaintenanceContext -MusicDir $MusicDir
$ytDlp = $Maintenance.Config.YtDlp
$OutputDir = $Maintenance.MusicDir
$CookieFile = $Maintenance.Config.CookieFile
'@)
if ($add -notmatch 'Resolve-MusicServerMaintenanceContext') { throw 'add_song maintenance resolver patch failed' }
Write-RepoText 'scripts/maintenance/add_song.ps1' $add

$fav = Read-RepoText 'scripts/maintenance/download_bilibili_favorites.ps1'
$fav = $fav.Replace('[string]$OutputDir = "E:\Project\MusicServer\Music"', "[Alias('MusicDir')]`r`n    [string]`$OutputDir = ''")
$fav = $fav.Replace("# yt-dlp 可执行文件路径`r`n`$ytDlp = \"C:\Users\dell\anaconda3\Scripts\yt-dlp.exe\"", @'
. (Join-Path $PSScriptRoot 'MusicServer.Maintenance.ps1')
$Maintenance = Resolve-MusicServerMaintenanceContext -MusicDir $OutputDir
$OutputDir = $Maintenance.MusicDir
$ytDlp = $Maintenance.Config.YtDlp
'@)
if ($fav -notmatch 'Resolve-MusicServerMaintenanceContext') { throw 'favorites maintenance resolver patch failed' }
Write-RepoText 'scripts/maintenance/download_bilibili_favorites.ps1' $fav

Write-Host 'Patch 5/9: configurable-library Pester coverage'
$testFile = @'
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force

Describe 'Configurable music library' {
    BeforeEach {
        $script:OldMusicDirEnv = [Environment]::GetEnvironmentVariable('MUSICSERVER_MUSIC_DIR')
        [Environment]::SetEnvironmentVariable('MUSICSERVER_MUSIC_DIR', $null)
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_library_' + [guid]::NewGuid().ToString('N'))
        $script:Config = New-MusicServerConfig -Root $script:Root
        Initialize-MusicServerState -Config $script:Config -SkipLibrary
        Initialize-MusicServerDatabase -DbPath (Join-Path $script:Config.StateDir 'musicserver.db') -SqliteExe $script:Config.Sqlite
        Initialize-MusicServerSchema
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_MUSIC_DIR', $script:OldMusicDirEnv)
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses the immutable default when no override is configured' {
        $expected = Get-DefaultMusicDir -Root $script:Config.Root
        (Resolve-ConfiguredMusicDir -Config $script:Config) | Should Be $expected
    }

    It 'persists a custom path and restores it in a fresh config object' {
        $custom = Join-Path $script:Root 'external library'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        $fresh = New-MusicServerConfig -Root $script:Root
        (Resolve-ConfiguredMusicDir -Config $fresh) | Should Be ([IO.Path]::GetFullPath($custom))
    }

    It 'reset returns to the true default even after Config.MusicDir was mutated' {
        $custom = Join-Path $script:Root 'custom'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        $script:Config.MusicDir | Should Be ([IO.Path]::GetFullPath($custom))
        Remove-AppSettingDb -Key 'music_library_path'
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        $script:Config.MusicDir | Should Be (Get-DefaultMusicDir -Root $script:Config.Root)
        $script:Config.DailyDir | Should Be (Join-Path $script:Config.MusicDir 'DailyMix')
    }

    It 'environment override wins over SQLite' {
        $databasePath = Join-Path $script:Root 'database-library'
        $envPath = Join-Path $script:Root 'environment-library'
        Set-AppSettingDb -Key 'music_library_path' -Value $databasePath
        [Environment]::SetEnvironmentVariable('MUSICSERVER_MUSIC_DIR', $envPath)
        (Resolve-ConfiguredMusicDir -Config $script:Config) | Should Be ([IO.Path]::GetFullPath($envPath))
    }

    It 'round-trips Unicode spaces and apostrophes through parameterized SQLite' {
        $custom = Join-Path $script:Root "音乐\My Music O'Brien"
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        (Get-AppSettingDb -Key 'music_library_path') | Should Be $custom
        (Resolve-ConfiguredMusicDir -Config $script:Config) | Should Be ([IO.Path]::GetFullPath($custom))
    }

    It 'preserves a configured unavailable directory and does not create a default library' {
        $custom = Join-Path $script:Root 'offline-drive\Music'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        (Initialize-MusicServerLibrary -Config $script:Config) | Should Be $false
        (Test-Path -LiteralPath (Get-DefaultMusicDir -Root $script:Config.Root)) | Should Be $false
        $script:Config.MusicDir | Should Be ([IO.Path]::GetFullPath($custom))
    }

    It 'rejects a file path as a music library' {
        $file = Join-Path $script:Root 'not-a-directory.txt'
        Set-Content -LiteralPath $file -Value 'x' -Encoding Ascii
        $validation = Test-MusicLibraryPath -Path $file
        $validation.Valid | Should Be $false
        $validation.Reason | Should Be 'IS_FILE'
    }

    It 'changing the effective path does not move or delete existing music' {
        $default = Get-DefaultMusicDir -Root $script:Config.Root
        New-Item -ItemType Directory -Force -Path $default | Out-Null
        $song = Join-Path $default 'keep-me.mp3'
        Set-Content -LiteralPath $song -Value 'audio' -Encoding Ascii
        $custom = Join-Path $script:Root 'new-library'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        (Test-Path -LiteralPath $song -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $custom) | Should Be $false
    }

    It 'writes a valid escaped Navidrome MusicFolder and is idempotent' {
        $toml = Join-Path $script:Root 'navidrome.toml'
        [IO.File]::WriteAllText($toml, "MusicFolder = 'C:\Old'`r`n", (New-Object Text.UTF8Encoding($false)))
        $custom = 'E:\音乐\My Music'
        (Sync-NavidromeMusicFolder -NdConfigPath $toml -NewMusicFolder $custom) | Should Be $true
        (Get-Content -LiteralPath $toml -Raw -Encoding UTF8).Trim() | Should Be 'MusicFolder = "E:\\音乐\\My Music"'
        (Sync-NavidromeMusicFolder -NdConfigPath $toml -NewMusicFolder $custom) | Should Be $false
    }
}
'@
Write-RepoText -Path 'tests/MusicServer.ConfigurableLibrary.Tests.ps1' -Text $testFile

$workflow = Read-RepoText '.github/workflows/core-tests.yml'
$workflow = $workflow.Replace("state = @('Core', 'Database', 'V2', 'WorkerConcurrency', 'Recommendation', 'LegacyRetirement', 'Listening', 'Web', 'Tauri')", "state = @('Core', 'Database', 'V2', 'WorkerConcurrency', 'Recommendation', 'LegacyRetirement', 'Listening', 'Web', 'Tauri', 'ConfigurableLibrary')")
if ($workflow -notmatch 'ConfigurableLibrary') { throw 'CI state suite registration failed' }
Write-RepoText '.github/workflows/core-tests.yml' $workflow

$tauriTests = Read-RepoText 'tests/MusicServer.Tauri.Tests.ps1'
$tauriAnchor = "        `$smoke | Should Match 'ServicesStopped'"
if (-not $tauriTests.Contains('withGlobalTauri')) {
    if (-not $tauriTests.Contains($tauriAnchor)) { throw 'Tauri test insertion anchor missing' }
    $tauriTests = $tauriTests.Replace($tauriAnchor, $tauriAnchor + "`r`n        `$tauriConf = Get-Content -LiteralPath (Join-Path `$ProjectRoot 'src-tauri\tauri.conf.json') -Raw`r`n        `$tauriConf | Should Match '\"withGlobalTauri\"\s*:\s*true'`r`n        `$web | Should Match 'window\.__TAURI__\?\.dialog'`r`n        `$web | Should Match 'window\.__TAURI__\?\.core'")
    Write-RepoText 'tests/MusicServer.Tauri.Tests.ps1' $tauriTests
}

Write-Host 'Patch 6/9: installed APP external-library smoke'
$workflow = Read-RepoText '.github/workflows/core-tests.yml'
$smokeAnchor = @'
            Write-Host "portable runtime ready -> $appHome"
            Write-Host "service pair -> UI=$($pair.Ui) API=$($pair.Api)"
'@
if (-not $workflow.Contains('external library ready ->')) {
    if (-not $workflow.Contains($smokeAnchor)) { throw 'installed smoke insertion anchor missing' }
    $externalSmoke = @'

            # Configure an external library through the installed API, then
            # restart the desktop APP and prove all media endpoints use it.
            $externalLibrary = Join-Path $env:RUNNER_TEMP 'MusicServerExternalLibrary'
            Remove-Item -LiteralPath $externalLibrary -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $externalLibrary | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $externalLibrary 'external-test.wav'), [byte[]](82,73,70,70,0,0,0,0,87,65,86,69))
            [IO.File]::WriteAllText((Join-Path $externalLibrary 'external-test.lrc'), "[00:00.00]external smoke`r`n", (New-Object Text.UTF8Encoding($false)))

            $settingsUri = "http://127.0.0.1:$($pair.Api)/api/settings/music-library"
            $payload = @{ path = $externalLibrary } | ConvertTo-Json -Compress
            $setResult = Invoke-RestMethod -Uri $settingsUri -Method Put -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 15
            if (-not $setResult.accepted -or -not $setResult.requires_restart) { throw 'Installed APP did not accept external music library setting.' }

            $kill = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', "$($desktop.Id)", '/T', '/F') -Wait -PassThru -NoNewWindow
            if ($kill.ExitCode -ne 0) { throw "Failed to stop installed APP before configured-library restart: $($kill.ExitCode)" }
            try { $desktop.WaitForExit(5000) | Out-Null } catch {}
            $desktop = $null

            $closedDeadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
              $open = $false
              foreach ($port in @(8787,8788,8789,8790,8791,8792)) {
                try {
                  $client = New-Object Net.Sockets.TcpClient
                  try { if ($client.ConnectAsync('127.0.0.1',$port).Wait(200)) { $open = $true; break } } finally { $client.Dispose() }
                } catch {}
              }
              if (-not $open) { break }
              Start-Sleep -Milliseconds 300
            } while ([DateTime]::UtcNow -lt $closedDeadline)
            if ($open) { throw 'Services did not stop before configured-library restart.' }

            # The first default startup may have created an empty default Music.
            # Remove only that empty fixture directory so the second startup can
            # prove a configured external path does not recreate it.
            $defaultMusic = Join-Path $appHome 'Music'
            if (Test-Path -LiteralPath $defaultMusic -PathType Container) {
              $defaultChildren = @(Get-ChildItem -LiteralPath $defaultMusic -Force -ErrorAction SilentlyContinue)
              if ($defaultChildren.Count -gt 0) { throw 'CI default Music fixture unexpectedly contains files; refusing to delete it.' }
              Remove-Item -LiteralPath $defaultMusic -Force
            }

            $desktop = Start-Process -FilePath $appExe.FullName -WorkingDirectory $installDir -PassThru
            $pair = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(75)
            do {
              if ($desktop.HasExited) { throw "Installed APP exited during configured-library restart with code $($desktop.ExitCode)." }
              $pair = Test-CurrentPair
              if ($pair) { break }
              Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $pair) { throw 'Installed APP did not restart with configured external library.' }

            $settingsUri = "http://127.0.0.1:$($pair.Api)/api/settings/music-library"
            $settings = Invoke-RestMethod -Uri $settingsUri -Method Get -TimeoutSec 15
            if ([IO.Path]::GetFullPath([string]$settings.path) -ne [IO.Path]::GetFullPath($externalLibrary)) {
              throw "Configured library was not restored after restart: $($settings.path)"
            }
            if (Test-Path -LiteralPath $defaultMusic) { throw 'Custom-library startup recreated the misleading default Music directory.' }

            $library = Invoke-RestMethod -Uri "http://127.0.0.1:$($pair.Api)/api/library" -Method Get -TimeoutSec 20
            $items = @($library.items)
            if ($items.Count -ne 1) { throw "Expected one external library item, got $($items.Count)." }
            $item = $items[0]
            if (-not $item.id) { throw 'External library item has no id.' }
            $stream = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($pair.Api)/api/library/$($item.id)/stream" -TimeoutSec 15
            if ($stream.StatusCode -ne 200) { throw "External stream failed: $($stream.StatusCode)" }
            $lyrics = Invoke-RestMethod -Uri "http://127.0.0.1:$($pair.Api)/api/library/$($item.id)/lyrics" -TimeoutSec 15
            if (-not $lyrics.available) { throw 'External adjacent LRC was not available.' }

            $reset = Invoke-RestMethod -Uri $settingsUri -Method Delete -TimeoutSec 15
            $expectedDefault = [IO.Path]::GetFullPath($defaultMusic)
            if ([IO.Path]::GetFullPath([string]$reset.path) -ne $expectedDefault) {
              throw "Reset did not return the immutable default path: $($reset.path)"
            }
            if ([IO.Path]::GetFullPath([string]$reset.daily_dir) -ne [IO.Path]::GetFullPath((Join-Path $defaultMusic 'DailyMix'))) {
              throw "Reset returned the wrong DailyMix path: $($reset.daily_dir)"
            }
            Write-Host "external library ready -> $externalLibrary"
'@
    $workflow = $workflow.Replace($smokeAnchor, $smokeAnchor + $externalSmoke)
    Write-RepoText '.github/workflows/core-tests.yml' $workflow
}

Write-Host 'Patch 7/9: documentation'
$readme = Read-RepoText 'README.md'
if (-not $readme.Contains('## 音乐库位置')) {
    $anchor = '安装包内包含 SQLite，因此 UI/API 和状态库启动不要求用户另装 sqlite3。Bilibili 下载、转码和 Navidrome 集成仍分别需要 yt-dlp、ffmpeg/ffprobe、Navidrome；这些大型/外部组件不塞进桌面 runtime。'
    if (-not $readme.Contains($anchor)) { throw 'README insertion anchor missing' }
    $section = @'

## 音乐库位置

安装版默认音乐库为：

```text
%LOCALAPPDATA%\com.musicserver.desktop\Music
```

用户可以在 APP 的“音乐库设置”中选择任意本地目录，例如 `D:\Music` 或 `E:\MyMusic`。配置持久化在 SQLite `app_settings` 中；`MUSICSERVER_MUSIC_DIR` 仅作为开发/高级用户 override，优先级高于 SQLite 设置。

更改音乐库位置**只改变 MusicServer 使用的目录，不会移动、复制或删除原有歌曲**。如果配置的是暂时离线的移动硬盘，MusicServer 会保留该设置并显示“不可用”，不会静默切回空的默认目录。恢复默认会重新使用 `<APP_HOME>\Music`。

歌词继续采用邻接文件约定：`Song.mp3` 与 `Song.lrc` 放在同一目录且 basename 相同。修改音乐库后需要重启 APP，让 UI/API/worker/Navidrome 全部使用新的目录。
'@
    $readme = $readme.Replace($anchor, $anchor + $section)
    Write-RepoText 'README.md' $readme
}

$guide = Read-RepoText 'docs/USER_GUIDE.zh-CN.md'
if (-not $guide.Contains('## 1.1 配置音乐库位置')) {
    $anchor = '如果设置了环境变量 `MUSICSERVER_APP_HOME`，则以该目录为准。'
    if (-not $guide.Contains($anchor)) { throw 'USER_GUIDE insertion anchor missing' }
    $section = @'

## 1.1 配置音乐库位置

安装版默认音乐库：

```text
%LOCALAPPDATA%\com.musicserver.desktop\Music
```

在 MusicServer APP 中打开“音乐库设置”，可以：

- **选择文件夹**：使用 Windows 原生目录选择器，例如 `D:\Music`、`E:\MyMusic`；
- **打开文件夹**：在资源管理器中打开当前有效音乐库；
- **恢复默认**：重新使用 `<APP_HOME>\Music`。

路径配置保存在 SQLite 中。修改位置不会自动移动、复制或删除任何现有歌曲；切换完成后请重启 MusicServer。如果配置的移动硬盘暂时不存在，APP 会保留原路径并显示“音乐库当前不可用”，不会偷偷切换到新的空目录。

歌曲与歌词使用同名邻接方式：

```text
Music\
├─ Song.mp3
└─ Song.lrc
```

即 `.lrc` 与音频文件放在同一目录，文件名相同。
'@
    $guide = $guide.Replace($anchor, $anchor + $section)
    Write-RepoText 'docs/USER_GUIDE.zh-CN.md' $guide
}

$agents = Read-RepoText 'AGENTS.md'
if (-not $agents.Contains('MUSICSERVER_MUSIC_DIR')) {
    $agents = $agents.Replace('MUSICSERVER_APP_HOME', "MUSICSERVER_APP_HOME`r`nMUSICSERVER_MUSIC_DIR")
    $anchor = 'for the writable runtime/data home. `MUSICSERVER_APP_HOME` can override it.'
    if (-not $agents.Contains($anchor)) { throw 'AGENTS music library insertion anchor missing' }
    $rules = @'

The music library is independently configurable. Runtime resolution order is `MUSICSERVER_MUSIC_DIR` -> SQLite `app_settings.music_library_path` -> `<APP_HOME>\Music`. All runtime entry points must use the same resolved `Config.MusicDir`, and `Config.DailyDir` must always be `<MusicDir>\DailyMix`. A missing configured custom path is an unavailable library, not a signal to fall back to or create the default library. Never move/copy/delete user music when changing this setting. Adjacent `Song.lrc` remains the lyric contract for `Song.mp3`.
'@
    $agents = $agents.Replace($anchor, $anchor + $rules)
    Write-RepoText 'AGENTS.md' $agents
}

Write-Host 'Patch 8/9: maintenance docs and layout references'
$agents = Read-RepoText 'AGENTS.md'
if (-not $agents.Contains('MusicServer.Maintenance.ps1')) {
    $agents = $agents.Replace('│     ├─ fetch_lyrics.ps1', "│     ├─ MusicServer.Maintenance.ps1 # shared configured-library resolver`r`n│     ├─ fetch_lyrics.ps1")
    Write-RepoText 'AGENTS.md' $agents
}

$guide = Read-RepoText 'docs/USER_GUIDE.zh-CN.md'
if (-not $guide.Contains('MusicServer.Maintenance.ps1')) {
    $guide = $guide.Replace('│   ├── download_bilibili_favorites.ps1', "│   ├── MusicServer.Maintenance.ps1    # 维护脚本共享路径解析`r`n│   ├── download_bilibili_favorites.ps1")
    Write-RepoText 'docs/USER_GUIDE.zh-CN.md' $guide
}

Write-Host 'Patch 9/9: preflight exact files'
$parseFiles = @(
    'MusicServer.Core.psm1','MusicServer.State.psm1','music_api.ps1','start_musicserver_ui.ps1',
    'wanted_worker.ps1','daily_recommend.ps1','daily_cleanup.ps1',
    'scripts/maintenance/MusicServer.Maintenance.ps1','scripts/maintenance/fetch_lyrics.ps1',
    'scripts/maintenance/fix_one_lyric.ps1','scripts/maintenance/fix_tags.ps1',
    'scripts/maintenance/add_song.ps1','scripts/maintenance/download_bilibili_favorites.ps1',
    'tests/MusicServer.ConfigurableLibrary.Tests.ps1'
)
foreach ($path in $parseFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host "$path :: $($_.Message)" }
        throw "PowerShell parser failed: $path"
    }
}

if ((Read-RepoText 'MusicServer.State.psm1') -notmatch 'return \(Get-DefaultMusicDir -Root \$Config\.Root\)') { throw 'immutable default resolver missing' }
if ((Read-RepoText 'src-tauri/tauri.conf.json') -notmatch '"withGlobalTauri"\s*:\s*true') { throw 'withGlobalTauri is not enabled' }
if ((Read-RepoText 'scripts/maintenance/fetch_lyrics.ps1') -match 'E:\\Project\\MusicServer\\Music') { throw 'fetch_lyrics still hardcodes the old music library' }
if ((Read-RepoText 'scripts/maintenance/fix_one_lyric.ps1') -match 'E:\\Project\\MusicServer\\Music') { throw 'fix_one_lyric still hardcodes the old music library' }
if ((Read-RepoText 'scripts/maintenance/fix_tags.ps1') -match 'E:\\Project\\MusicServer\\Music') { throw 'fix_tags still hardcodes the old music library' }
if ((Read-RepoText 'scripts/maintenance/add_song.ps1') -match 'E:\\Project\\MusicServer\\Music') { throw 'add_song still hardcodes the old music library' }
if ((Read-RepoText 'scripts/maintenance/download_bilibili_favorites.ps1') -match 'E:\\Project\\MusicServer\\Music') { throw 'favorites downloader still hardcodes the old music library' }

Write-Host 'PR19 completion patch prepared successfully.'
