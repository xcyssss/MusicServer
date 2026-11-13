$ProjectRoot = Split-Path -Parent $PSScriptRoot

function New-AppHomePinKey {
    $key = 'HKCU:\Software\MusicServerRuntimeTests-' + [guid]::NewGuid().ToString('N')
    New-Item -Path $key -Force | Out-Null
    return $key
}

Describe 'MusicServer APP_HOME path resolution' {
    BeforeEach {
        $script:Checkout = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_checkout_' + [guid]::NewGuid().ToString('N'))
        $script:AppHome = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_app_home_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Checkout,$script:AppHome -Force | Out-Null
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
        $script:OldAppHome = [Environment]::GetEnvironmentVariable('MUSICSERVER_APP_HOME')
        $script:OldPinKey = [Environment]::GetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', 'Process')
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $null)
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:OldAppHome)
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $script:OldPinKey, 'Process')
        Remove-Item -LiteralPath $script:Checkout,$script:AppHome -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps persistent paths under explicit APP_HOME instead of the checkout root' {
        foreach ($relative in @('Music', 'DailyMix_data', 'Navidrome\Data', 'logs', 'backups', 'secrets')) {
            New-Item -ItemType Directory -Path (Join-Path $script:Checkout $relative) -Force | Out-Null
        }
        New-Item -ItemType File -Path (Join-Path $script:Checkout 'cookies.txt') -Force | Out-Null

        $config = New-MusicServerConfig -Root $script:Checkout -AppHome $script:AppHome

        $config.AppHome | Should Be ([IO.Path]::GetFullPath($script:AppHome))
        $config.DataDir | Should Be (Join-Path $script:AppHome 'DailyMix_data')
        $config.StateDir | Should Be (Join-Path $script:AppHome 'DailyMix_data\state')
        $config.MusicDir | Should Be (Join-Path $script:AppHome 'Music')
        $config.NdDb | Should Be (Join-Path $script:AppHome 'Navidrome\Data\navidrome.db')
        $config.CookieFile | Should Be (Join-Path $script:AppHome 'secrets\cookies.txt')
        $config.LogDir | Should Be (Join-Path $script:AppHome 'logs')
        $config.BackupDir | Should Be (Join-Path $script:AppHome 'backups')
    }

    It 'uses MUSICSERVER_APP_HOME when no explicit app home is supplied' {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:AppHome)

        $config = New-MusicServerConfig -Root $script:Checkout

        $config.AppHome | Should Be ([IO.Path]::GetFullPath($script:AppHome))
        $config.MusicDir | Should Be (Join-Path $script:AppHome 'Music')
    }

    It 'uses a relative sidecar before stale environment and pin values' {
        $resolvedHome = Join-Path $script:Checkout 'data with spaces'
        New-Item -ItemType Directory -Path $resolvedHome | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Checkout 'musicserver.paths.json') -Value '{"schema":1,"app_home":"data with spaces"}' -Encoding UTF8
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', (Join-Path $script:Checkout 'missing'))
        Push-Location $env:SystemRoot
        try { (New-MusicServerConfig -Root $script:Checkout).AppHome | Should Be $resolvedHome }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $script:Checkout 'missing') | Should Be $false
    }

    It 'keeps relative configuration usable after the enclosing directory moves' {
        $resolvedHome = Join-Path $script:Checkout 'data'
        New-Item -ItemType Directory -Path $resolvedHome | Out-Null
        Set-Content -LiteralPath (Join-Path $resolvedHome 'history.txt') -Value 'preserved'
        Set-Content -LiteralPath (Join-Path $script:Checkout 'musicserver.paths.json') -Value '{"schema":1,"app_home":"data"}' -Encoding UTF8
        $old = $script:Checkout
        $moved = $old + '_moved'
        Move-Item -LiteralPath $old -Destination $moved
        $script:Checkout = $moved
        $config = New-MusicServerConfig -Root $moved
        $config.AppHome | Should Be (Join-Path $moved 'data')
        (Get-Content -LiteralPath (Join-Path $config.AppHome 'history.txt')) | Should Be 'preserved'
        Test-Path -LiteralPath $old | Should Be $false
    }

    It 'refuses missing configured homes without writing or choosing a fallback' {
        $missing = Join-Path $script:Checkout 'missing'
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $missing)
        { New-MusicServerConfig -Root $script:Checkout } | Should Throw 'APP_HOME_UNAVAILABLE'
        Set-Content -LiteralPath (Join-Path $script:Checkout 'musicserver.paths.json') -Value '{"schema":1,"app_home":"missing"}' -Encoding UTF8
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:AppHome)
        { New-MusicServerConfig -Root $script:Checkout } | Should Throw 'APP_HOME_UNAVAILABLE'
        Test-Path -LiteralPath $missing | Should Be $false
    }

    It 'rejects a malformed sidecar instead of using the environment' {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:AppHome)
        foreach ($json in @('broken', '{"schema":2,"app_home":"."}', '{"schema":1,"app_home":".","typo":true}')) {
            Set-Content -LiteralPath (Join-Path $script:Checkout 'musicserver.paths.json') -Value $json -Encoding UTF8
            { New-MusicServerConfig -Root $script:Checkout } | Should Throw 'PATH_CONFIG_INVALID'
        }
    }

    It 'anchors explicit relative arguments to the script rather than the caller' {
        Push-Location $env:SystemRoot
        try { (New-MusicServerConfig -Root $script:Checkout -AppHome '.\data').AppHome | Should Be (Join-Path $script:Checkout 'data') }
        finally { Pop-Location }
        { Resolve-MusicServerAnchoredPath -Path 'C:ambiguous' -BasePath $script:Checkout } | Should Throw
    }

    It 'uses the machine APP_HOME pin when no environment override is supplied' {
        $pin = New-AppHomePinKey
        try {
            Set-ItemProperty -LiteralPath $pin -Name 'AppHome' -Value $script:AppHome -Type String
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $pin, 'Process')

            $config = New-MusicServerConfig -Root $script:Checkout

            $config.AppHome | Should Be ([IO.Path]::GetFullPath($script:AppHome))
            $config.StateDir | Should Be (Join-Path $script:AppHome 'DailyMix_data\state')
        } finally {
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $script:OldPinKey, 'Process')
            Remove-Item -LiteralPath $pin -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'prefers MUSICSERVER_APP_HOME over the machine pin' {
        $pin = New-AppHomePinKey
        $other = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_pinned_' + [guid]::NewGuid().ToString('N'))
        try {
            Set-ItemProperty -LiteralPath $pin -Name 'AppHome' -Value $other -Type String
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $pin, 'Process')
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:AppHome)

            $config = New-MusicServerConfig -Root $script:Checkout

            $config.AppHome | Should Be ([IO.Path]::GetFullPath($script:AppHome))
        } finally {
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $script:OldPinKey, 'Process')
            Remove-Item -LiteralPath $pin -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ignores a blank pin and keeps the platform default home' {
        $pin = New-AppHomePinKey
        try {
            Set-ItemProperty -LiteralPath $pin -Name 'AppHome' -Value '   ' -Type String
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $pin, 'Process')

            $config = New-MusicServerConfig -Root $script:Checkout

            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            $config.AppHome | Should Be ([IO.Path]::GetFullPath((Join-Path $localAppData 'com.musicserver.desktop')))
        } finally {
            [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $script:OldPinKey, 'Process')
            Remove-Item -LiteralPath $pin -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the pin outside the registry keys the uninstaller removes' {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME_PIN_KEY', $null, 'Process')

        # The NSIS uninstaller deletes HKCU\Software\<manufacturer>\<product> and
        # %APPDATA%\<bundle id>, so a pin stored under either would not survive a
        # reinstall -- and a reinstall is exactly when the default home came back.
        (Get-MusicServerAppHomePinKey) | Should Be 'HKCU:\Software\MusicServerRuntime'
        (Get-MusicServerAppHomePinKey) | Should Not Match 'software\\musicserver\\'
    }

    It 'does not let checkout data change the default music library' {        New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'Music') -Force | Out-Null
        $config = New-MusicServerConfig -Root $script:Checkout -AppHome $script:AppHome

        (Get-DefaultMusicDir -AppHome $config.AppHome) | Should Be (Join-Path $script:AppHome 'Music')
        (Get-DefaultMusicDir -AppHome $config.AppHome) | Should Not Be (Join-Path $script:Checkout 'Music')
    }

    It 'can resolve the default library before the first database exists' {
        $config = New-MusicServerConfig -Root $script:Checkout -AppHome $script:AppHome
        (Resolve-ConfiguredMusicDir -Config $config) | Should Be (Join-Path $script:AppHome 'Music')
    }

    It 'creates Navidrome configuration in APP_HOME with no checkout paths' {
        $config = New-MusicServerConfig -Root $script:Checkout -AppHome $script:AppHome
        Initialize-MusicServerState -Config $config -SkipLibrary

        Test-Path -LiteralPath $config.NdConfig -PathType Leaf | Should Be $true
        $content = Get-Content -LiteralPath $config.NdConfig -Raw -Encoding UTF8
        $musicFolderText = $config.MusicDir.Replace('\', '\\')
        $navidromeDataText = (Split-Path -Parent $config.NdDb).Replace('\', '\\')
        $content | Should Match ([regex]::Escape($musicFolderText))
        $content | Should Match ([regex]::Escape($navidromeDataText))
        $content | Should Not Match ([regex]::Escape($script:Checkout))
    }
}
