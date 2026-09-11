$ProjectRoot = Split-Path -Parent $PSScriptRoot

Describe 'MusicServer APP_HOME path resolution' {
    BeforeEach {
        $script:Checkout = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_checkout_' + [guid]::NewGuid().ToString('N'))
        $script:AppHome = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_app_home_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Checkout,$script:AppHome -Force | Out-Null
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
        $script:OldAppHome = [Environment]::GetEnvironmentVariable('MUSICSERVER_APP_HOME')
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $null)
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:OldAppHome)
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

    It 'does not let checkout data change the default music library' {
        New-Item -ItemType Directory -Path (Join-Path $script:Checkout 'Music') -Force | Out-Null
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
