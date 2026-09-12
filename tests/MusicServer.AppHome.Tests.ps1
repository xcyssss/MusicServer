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
