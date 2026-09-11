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
        $script:Config = New-MusicServerConfig -Root $ProjectRoot -AppHome $script:Root
        Initialize-MusicServerState -Config $script:Config -SkipLibrary
        Initialize-MusicServerDatabase -DbPath (Join-Path $script:Config.StateDir 'musicserver.db') -SqliteExe $script:Config.Sqlite
        Initialize-MusicServerSchema
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_MUSIC_DIR', $script:OldMusicDirEnv)
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses the immutable default when no override is configured' {
        $expected = Get-DefaultMusicDir -AppHome $script:Config.AppHome
        (Resolve-ConfiguredMusicDir -Config $script:Config) | Should Be $expected
    }

    It 'persists a custom path and restores it in a fresh config object' {
        $custom = Join-Path $script:Root 'external library'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        $fresh = New-MusicServerConfig -Root $ProjectRoot -AppHome $script:Root
        (Resolve-ConfiguredMusicDir -Config $fresh) | Should Be ([IO.Path]::GetFullPath($custom))
    }

    It 'reset returns to the true default even after Config.MusicDir was mutated' {
        $custom = Join-Path $script:Root 'custom'
        Set-AppSettingDb -Key 'music_library_path' -Value $custom
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        $script:Config.MusicDir | Should Be ([IO.Path]::GetFullPath($custom))
        Remove-AppSettingDb -Key 'music_library_path'
        Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
        $script:Config.MusicDir | Should Be (Get-DefaultMusicDir -AppHome $script:Config.AppHome)
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
        (Test-Path -LiteralPath (Get-DefaultMusicDir -AppHome $script:Config.AppHome)) | Should Be $false
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
        $default = Get-DefaultMusicDir -AppHome $script:Config.AppHome
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

    Context 'library display mode' {
        It 'defaults to the traditional names when nothing was ever chosen' {
            (Get-LibraryDisplayModeDb) | Should Be 'raw'
            (Get-AppSettingDb -Key 'library_display_mode') | Should BeNullOrEmpty
        }

        It 'round-trips the canonical choice' {
            Set-LibraryDisplayModeDb -Mode 'canonical'
            (Get-LibraryDisplayModeDb) | Should Be 'canonical'
            (Get-AppSettingDb -Key 'library_display_mode') | Should Be 'canonical'
            Set-LibraryDisplayModeDb -Mode 'raw'
            (Get-LibraryDisplayModeDb) | Should Be 'raw'
        }

        It 'falls back to the traditional names for a stored value it does not know' {
            # A value written by a future or corrupted build must not select a mode
            # this build cannot render, and must never break the library read.
            Set-AppSettingDb -Key 'library_display_mode' -Value 'fancy'
            (Get-LibraryDisplayModeDb) | Should Be 'raw'
            Remove-AppSettingDb -Key 'library_display_mode'
            (Get-LibraryDisplayModeDb) | Should Be 'raw'
        }

        It 'refuses to store a mode outside the vocabulary' {
            { Set-LibraryDisplayModeDb -Mode 'fancy' } | Should Throw
            (Get-LibraryDisplayModeDb) | Should Be 'raw'
        }

        It 'choosing a display mode never touches the music library or its files' {
            $default = Get-DefaultMusicDir -AppHome $script:Config.AppHome
            New-Item -ItemType Directory -Force -Path $default | Out-Null
            $song = Join-Path $default 'keep-me.mp3'
            Set-Content -LiteralPath $song -Value 'audio' -Encoding Ascii
            Set-LibraryDisplayModeDb -Mode 'canonical'
            Apply-ConfiguredMusicDir -Config $script:Config | Out-Null
            (Test-Path -LiteralPath $song -PathType Leaf) | Should Be $true
            $script:Config.MusicDir | Should Be ([IO.Path]::GetFullPath($default))
        }
    }
}
