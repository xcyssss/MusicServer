$ProjectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'MusicServer.DesktopSmoke.ps1')

Describe 'Owned API startup wait' {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'start_musicserver_ui.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($name in @('Test-ApiReady', 'Write-UiLog', 'Start-MusicServerApi')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    BeforeEach {
        $Root = $TestDrive
        $ApiScript = Join-Path $TestDrive 'api.ps1'
        Set-Content -LiteralPath $ApiScript -Value '# fixture'
        $ApiPrefix = 'http://127.0.0.1:8787/'
        $ApiOutLog = Join-Path $TestDrive 'api.out'
        $ApiErrLog = Join-Path $TestDrive 'api.err'
        Mock Write-UiLog {}
        Mock Start-Process { [pscustomobject]@{ Id = 123; HasExited = $false; ExitCode = 0 } }
        Mock Test-ApiReady { $false }
        Mock Test-ApiReady { $false } -ParameterFilter { $TimeoutMilliseconds -eq 100 }
        Mock Start-Sleep { [Threading.Thread]::Sleep($Milliseconds) }
    }

    It 'reuses an existing API without spawning or sleeping' {
        Mock Test-ApiReady { $true }
        Mock Start-Sleep { throw 'Must not sleep' }
        Start-MusicServerApi
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'detects an exited child before sleeping or polling it' {
        Mock Start-Process { [pscustomobject]@{ Id = 123; HasExited = $true; ExitCode = 7 } }
        Mock Start-Sleep { throw 'Must not sleep' }
        { Start-MusicServerApi } | Should Throw 'ExitCode=7'
        Assert-MockCalled Test-ApiReady -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }

    It 'probes the owned child immediately with a short timeout' {
        Mock Test-ApiReady { $true } -ParameterFilter { $TimeoutMilliseconds -eq 100 }
        Mock Start-Sleep { throw 'Must not sleep' }
        Start-MusicServerApi
        Assert-MockCalled Test-ApiReady -Times 1 -Exactly -Scope It -ParameterFilter { $TimeoutMilliseconds -eq 100 }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }

    It 'stops waiting when the total budget expires' {
        { Start-MusicServerApi -StartupTimeoutSeconds 1 } | Should Throw 'did not become healthy'
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
    }
}

Describe 'Installed APP shutdown outcome' {
    It 'accepts a taskkill tree error only when the APP has exited' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 128 } }
        $process = [pscustomobject]@{ Id = 123; HasExited = $false }
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $true }
        { Stop-MusicServerSmokeDesktop -Process $process } | Should Not Throw
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
    }

    It 'fails when the APP survives even if taskkill reports success' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $process = [pscustomobject]@{ Id = 123; HasExited = $false }
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        $threw = $false
        try { Stop-MusicServerSmokeDesktop -Process $process } catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'does not target an already exited APP PID' {
        Mock Start-Process { throw 'Must not kill an exited process.' }
        $process = [pscustomobject]@{ Id = 123; HasExited = $true }
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $true }
        { Stop-MusicServerSmokeDesktop -Process $process } | Should Not Throw
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}

Describe 'MusicServer Tauri desktop shell' {
    It 'uses Tauri v2 and the shared web directory' {
        $config = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\tauri.conf.json') -Raw)
        $config.'$schema' | Should Match 'schema.tauri.app/config/2'
        $config.build.devUrl | Should Match '127\.0\.0\.1:8790'
        $config.build.frontendDist | Should Be '../web'
        (Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\Cargo.toml') -Raw) | Should Match 'tauri = \{ version = "2"'
    }

    It 'rejects stale UI/API services and carries the smoke verifier' {
        $main = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\src\main.rs') -Raw
        $web = Get-Content -LiteralPath (Join-Path $ProjectRoot 'web\app.js') -Raw
        $api = Get-Content -LiteralPath (Join-Path $ProjectRoot 'music_api.ps1') -Raw
        $smoke = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests\verify_tauri_desktop.ps1') -Raw

        $main | Should Match 'BUILD_MARKER'
        $main | Should Match 'service_is_current'
        $main | Should Match 'FALLBACK_PAIRS'
        $main | Should Match '-UiPrefix'
        $main | Should Match '-ApiPrefix'
        $web | Should Match 'musicserver-development'
        $api | Should Match 'Get-MusicServerBuildIdentity'
        $smoke | Should Match 'CloseLaunchedApp'
        $smoke | Should Match 'ServicesStopped'
        $tauriConf = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\tauri.conf.json') -Raw
        $tauriConf | Should Match '"withGlobalTauri"\s*:\s*true'
        $main | Should Match 'app\.dialog\(\)'
        $web | Should Match 'window\.__TAURI__\?\.core'

        # Production navigates the Tauri WebView to the local PowerShell HTTP UI,
        # which is a remote origin to Tauri's ACL. Keep IPC permission scoped to
        # only the three owned UI ports instead of granting arbitrary web origins.
        $capability = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\capabilities\default.json') -Raw)
        $remoteUrls = @($capability.remote.urls)
        $remoteUrls.Count | Should Be 3
        ($remoteUrls -contains 'http://127.0.0.1:8790') | Should Be $true
        ($remoteUrls -contains 'http://127.0.0.1:8791') | Should Be $true
        ($remoteUrls -contains 'http://127.0.0.1:8792') | Should Be $true
        (@($capability.permissions) -contains 'dialog:allow-open') | Should Be $true
    }

    It 'keeps taskbar and tray together when minimized' {
        $main = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\src\main.rs') -Raw
        $cargo = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\Cargo.toml') -Raw

        # Without the feature TrayIconBuilder does not exist at all.
        $cargo | Should Match 'tauri = \{ version = "2", features = \["tray-icon"\] \}'
        $main | Should Match 'TrayIconBuilder::with_id\(TRAY_ID\)'
        $main | Should Match 'on_tray_icon_event'
        $main | Should Match 'restore_main_window'
        $main | Should Not Match 'window\.hide\(\)'
        $main | Should Not Match 'should_hide_to_tray'
        $main | Should Match 'window\.unminimize\(\)'
        # Closing the window still exits and stops this APP's owned service tree:
        # minimize-to-tray must not turn the close button into a second hide.
        $main | Should Match 'tauri::WindowEvent::Destroyed'
    }

    It 'packages a writable portable runtime instead of embedding the source-tree path' {
        $configText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\tauri.conf.json') -Raw
        $config = ConvertFrom-Json -InputObject $configText
        $main = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\src\main.rs') -Raw
        $prepare = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\prepare_tauri_runtime.ps1') -Raw

        $config.build.beforeBuildCommand | Should Match 'prepare_tauri_runtime\.ps1'
        @($config.bundle.resources) -join ' ' | Should Match 'resources/runtime'
        $main | Should Not Match 'CARGO_MANIFEST_DIR'
        $main | Should Match 'LOCALAPPDATA'
        $main | Should Not Match 'find_development_checkout|historical checkout|executable ancestry'
        $main | Should Match 'stage_runtime'
        $main | Should Match 'MUSICSERVER_SQLITE'
        $prepare | Should Match 'start_musicserver_ui\.ps1'
        $prepare | Should Match 'music_api\.ps1'
        $prepare | Should Match 'wanted_worker\.ps1'
        $prepare | Should Match 'daily_recommend\.ps1'
        $prepare | Should Match 'sqlite3\.exe'
        $prepare | Should Not Match 'cookies\.txt'
    }

    It 'ships the daily recommendation generator and its installer-time task registrar' {
        $registrarPath = Join-Path $ProjectRoot 'register_daily_recommend.ps1'
        (Test-Path -LiteralPath $registrarPath -PathType Leaf) | Should Be $true
        $registrar = Get-Content -LiteralPath $registrarPath -Raw -Encoding UTF8
        $registrar | Should Match 'MusicServer_DailyRecommend'
        $registrar | Should Match 'daily_recommend\.ps1'
        $registrar | Should Match 'Unregister'
        $registrar | Should Match 'New-ScheduledTaskTrigger'
        $registrar | Should Match '-AppHome'
        # A plain Register-ScheduledTask refuses to run on battery and never
        # catches up a missed 07:00 start, which silently disables the task for
        # anyone on a laptop.
        $registrar | Should Match 'New-ScheduledTaskSettingsSet'
        $registrar | Should Match '-AllowStartIfOnBatteries'
        $registrar | Should Match '-DontStopIfGoingOnBatteries'
        $registrar | Should Match '-StartWhenAvailable'
        $registrar | Should Match '-Settings \$settings'

        $generator = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_recommend.ps1') -Raw -Encoding UTF8
        $generator | Should Match '\$AppHome'
        $generator | Should Match 'New-MusicServerConfig -Root \$Root -AppHome \$AppHome'
        # A fresh install has no likes or stars, so the local library must be able
        # to seed the generator, and it must keep the resolved singer rather than
        # the uploader.
        $generator | Should Match 'Get-LocalLibraryRows'
        $generator | Should Match '-LibraryFallback'
        # The local re-listen source ships with the generator.
        $generator | Should Match 'Select-LocalRecommendationTracks'
        $generator | Should Match 'local_library'
        $generator | Should Match 'Get-SongSearchQueries'

        $identity = Get-Content -LiteralPath (Join-Path $ProjectRoot 'MusicServer.Identity.psm1') -Raw -Encoding UTF8
        $identity | Should Match 'daily_recommend\.ps1'
        $identity | Should Match 'MusicServer\.Migration\.psm1'

        foreach ($scriptPath in @($registrarPath, (Join-Path $ProjectRoot 'daily_recommend.ps1'))) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
            @($errors).Count | Should Be 0
        }
    }

    It 'registers the daily recommendation task from the launcher without blocking startup' {
        $launcherPath = Join-Path $ProjectRoot 'start_musicserver_ui.ps1'
        $launcher = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
        $launcher | Should Match 'Initialize-MusicServerScheduledTasks'
        $launcher | Should Match 'MUSICSERVER_DISABLE_SCHEDULED_TASKS'
        $launcher | Should Match 'register_daily_recommend\.ps1'
        $launcher | Should Match 'Start-ScheduledTask'
        # An existing task registered with the old defaults must be repaired, and
        # a day that still has no rows must be retried rather than skipped.
        $launcher | Should Match 'Test-DailyRecommendTaskCurrent'
        $launcher | Should Match 'Test-DailyRecommendGeneratedToday'
        $launcher | Should Match 'daily_recommendations'
        $launcher | Should Match 'StartWhenAvailable'
        # The health check and the task registration must use the home this APP
        # resolved, not the directory the scripts happen to live in: when the two
        # disagree the day is generated into a database nobody reads.
        $launcher | Should Match 'Test-DailyRecommendGeneratedToday -AppHome \$AppHome'
        $launcher | Should Match '\$registerArgs = @\{ AppHome = \$AppHome \}'
        # One home for the whole tree: children resolve APP_HOME themselves.
        $launcher | Should Match '\$env:MUSICSERVER_APP_HOME = \$Config\.AppHome'
        # A denied Register-ScheduledTask must not skip the day's generation.
        $launcher | Should Match 'Start-MusicServerDailyRecommendBackfill'
        $launcher | Should Match 'WARN daily recommendation task repair failed'
        # A repair must carry the user's own schedule instead of resetting it.
        $launcher | Should Match 'Get-DailyRecommendTaskPreferences'
        $launcher | Should Match '& \$registrar @registerArgs'
        # The generator must follow the configured library rather than a path
        # frozen at registration time.
        $generatorText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_recommend.ps1') -Raw -Encoding UTF8
        $generatorText | Should Match 'Apply-ConfiguredMusicDir'
        $generatorText | Should Match '\$Config\.MusicDir'
        # A source checkout must not register machine state.
        $launcher | Should Match '\$Root ''\.git'''

        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$null, [ref]$errors)
        @($errors).Count | Should Be 0
    }

    It 'treats a daily recommendation task that cannot run on battery as stale' {
        $launcherPath = Join-Path $ProjectRoot 'start_musicserver_ui.ps1'
        $text = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
        $source = [regex]::Match($text, '(?s)function Test-DailyRecommendTaskCurrent \{.*?\n\}').Value
        $source | Should Not BeNullOrEmpty
        . ([scriptblock]::Create($source))

        $generator = Join-Path $ProjectRoot 'daily_recommend.ps1'
        function New-ProbeTask {
            param([string]$Arguments, [bool]$StartWhenAvailable, [bool]$DisallowBattery, [bool]$StopOnBattery)
            return [pscustomobject]@{
                Actions = @([pscustomobject]@{ Arguments = $Arguments })
                Settings = [pscustomobject]@{
                    StartWhenAvailable = $StartWhenAvailable
                    DisallowStartIfOnBatteries = $DisallowBattery
                    StopIfGoingOnBatteries = $StopOnBattery
                }
            }
        }
        $healthy = New-ProbeTask -Arguments "-File `"$generator`"" -StartWhenAvailable $true -DisallowBattery $false -StopOnBattery $false
        (Test-DailyRecommendTaskCurrent -Task $healthy -Generator $generator) | Should Be $true

        $batteryBlocked = New-ProbeTask -Arguments "-File `"$generator`"" -StartWhenAvailable $false -DisallowBattery $true -StopOnBattery $true
        (Test-DailyRecommendTaskCurrent -Task $batteryBlocked -Generator $generator) | Should Be $false

        $wrongScript = New-ProbeTask -Arguments '-File "C:\other\daily_recommend.ps1"' -StartWhenAvailable $true -DisallowBattery $false -StopOnBattery $false
        (Test-DailyRecommendTaskCurrent -Task $wrongScript -Generator $generator) | Should Be $false
        (Test-DailyRecommendTaskCurrent -Task $null -Generator $generator) | Should Be $false

        # A task whose generator matches but whose -AppHome points at another home
        # generates the day into a database this APP never reads.
        $otherHome = New-ProbeTask -Arguments "-File `"$generator`" -Count 20 -AppHome `"D:\other_home`"" -StartWhenAvailable $true -DisallowBattery $false -StopOnBattery $false
        (Test-DailyRecommendTaskCurrent -Task $otherHome -Generator $generator -AppHome 'E:\Project\MusicSever_app') | Should Be $false
        (Test-DailyRecommendTaskCurrent -Task $otherHome -Generator $generator -AppHome 'D:\other_home') | Should Be $true
        # Windows paths compare case-insensitively: a difference in case is not a
        # different home.
        (Test-DailyRecommendTaskCurrent -Task $otherHome -Generator $generator -AppHome 'd:\OTHER_HOME') | Should Be $true
        # Without a declared home the binding cannot be verified, so it is stale
        # rather than assumed current.
        $undeclaredHome = New-ProbeTask -Arguments "-File `"$generator`"" -StartWhenAvailable $true -DisallowBattery $false -StopOnBattery $false
        (Test-DailyRecommendTaskCurrent -Task $undeclaredHome -Generator $generator -AppHome 'D:\other_home') | Should Be $false
    }

    It 'keeps a user-customised daily recommendation schedule across a repair' {
        $launcherPath = Join-Path $ProjectRoot 'start_musicserver_ui.ps1'
        $text = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
        $source = [regex]::Match($text, '(?s)function Get-DailyRecommendTaskPreferences \{.*?\n\}').Value
        $source | Should Not BeNullOrEmpty
        . ([scriptblock]::Create($source))

        function New-PreferenceTask {
            param([string]$Arguments, [string]$StartBoundary)
            return [pscustomobject]@{
                Actions = @([pscustomobject]@{ Arguments = $Arguments })
                Triggers = @([pscustomobject]@{ StartBoundary = $StartBoundary })
            }
        }

        # The install directory moved, so the arguments point at the old path.
        $moved = New-PreferenceTask -Arguments '-NoProfile -ExecutionPolicy Bypass -File "D:\old\daily_recommend.ps1" -Count 35 -AppHome "D:\old"' -StartBoundary '2026-09-10T08:30:00+08:00'
        $preferences = Get-DailyRecommendTaskPreferences -Task $moved
        $preferences.Time | Should Be '08:30'
        $preferences.Count | Should Be 35

        $defaults = New-PreferenceTask -Arguments '-File "C:\x\daily_recommend.ps1" -Count 20 -AppHome "C:\x"' -StartBoundary '2026-09-10T07:00:00+08:00'
        $plain = Get-DailyRecommendTaskPreferences -Task $defaults
        $plain.Time | Should Be '07:00'
        $plain.Count | Should Be 20

        # A first install has no prior task and must fall back to the defaults.
        $empty = Get-DailyRecommendTaskPreferences -Task $null
        $empty.Time | Should Be ''
        $empty.Count | Should Be 0
    }

    It 'uses the shared content identity in services, build and smoke checks' {
        foreach ($relative in @('music_api.ps1', 'start_musicserver_ui.ps1', 'src-tauri/build.rs', 'tests/verify_tauri_desktop.ps1', '.github/workflows/core-tests.yml')) {
            $text = Get-Content -LiteralPath (Join-Path $ProjectRoot $relative) -Raw -Encoding UTF8
            $text | Should Match 'Get-MusicServerBuildIdentity'
        }
        (Get-Content (Join-Path $ProjectRoot 'src-tauri/src/main.rs') -Raw) | Should Match 'env!\("MUSICSERVER_BUILD_ID"\)'
    }

    It 'stages an executable runtime containing the shared HTTP input module' {
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $packageRoot = [IO.Path]::GetFullPath((Join-Path $tempParent ('musicserver_package_' + [guid]::NewGuid().ToString('N'))))
        if (-not $packageRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package fixture escaped the temporary directory.' }
        try {
            & (Join-Path $ProjectRoot 'scripts\prepare_tauri_runtime.ps1') -ProjectRoot $ProjectRoot -Destination $packageRoot | Out-Null
            $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'runtime-manifest.json') -Raw | ConvertFrom-Json
            $manifest.schema | Should Be 2
            Import-Module (Join-Path $ProjectRoot 'MusicServer.Identity.psm1') -Force
            $manifest.build_id | Should Be (Get-MusicServerBuildIdentity -Root $ProjectRoot)
            foreach ($entry in $manifest.files) {
                $file = Join-Path $packageRoot $entry.path
                (Get-Item -LiteralPath $file).Length | Should Be $entry.size
                (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $entry.sha256
            }
            ($manifest.runtime_files -contains 'MusicServer.Http.psm1') | Should Be $true
            ($manifest.runtime_files -contains 'daily_recommend.ps1') | Should Be $true
            ($manifest.runtime_files -contains 'register_daily_recommend.ps1') | Should Be $true
            ($manifest.runtime_files -contains 'MusicServer.Migration.psm1') | Should Be $true
            foreach ($relative in $manifest.runtime_files) { (Test-Path -LiteralPath (Join-Path $packageRoot $relative) -PathType Leaf) | Should Be $true }
            Import-Module (Join-Path $packageRoot 'MusicServer.Http.psm1') -Force
            $stream = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes('{}'))
            try {
                $request = [pscustomobject]@{ Headers = @{}; ContentLength64 = 2; InputStream = $stream }
                (Read-MusicServerJsonRequest -Request $request).Text | Should Be '{}'
            } finally { $stream.Dispose() }
        } finally {
            Remove-Module MusicServer.Http -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
        }
    }
}
