$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'Portable library order and metadata' {
    BeforeEach {
        $script:fixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Library.psm1') -Force
        $script:first = Join-Path $fixture.Config.MusicDir 'First.mp3'
        $script:second = Join-Path $fixture.Config.MusicDir 'Second.mp3'
        [IO.File]::WriteAllText($first, 'first recording')
        [IO.File]::WriteAllText($second, 'second recording')
        $script:items = @(
            [pscustomobject]@{id='old-first';path=$first;title='First';artist='Singer A';album='Album A';addedto='2024-01-01T00:00:00Z';duration=120},
            [pscustomobject]@{id='old-second';path=$second;title='Second';artist='Singer B';album='Album B';addedto='2024-01-02T00:00:00Z';duration=180}
        )
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:fixture }

    It 'keeps import order after timestamps change and after export to another root' {
        $original = @(Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items)
        [IO.File]::SetLastWriteTimeUtc($first, [DateTime]::UtcNow.AddDays(1))
        $rescanned = @(Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @($items[1],$items[0]))
        ($rescanned | Where-Object title -eq 'First').import_order | Should Be $original[0].import_order
        $zipPath = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'Migrated'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        Import-MusicServerLibraryManifest -Config $target | Out-Null
        $snapshotFirst = @(Get-MusicServerLibrarySnapshot -Config $target | Where-Object title -eq 'First')[0]
        $snapshotFirst.path | Should Be (Join-Path $migrated 'First.mp3')
        $snapshotFirst.id | Should Be (Get-MusicServerLocalIdentity -File (Join-Path $migrated 'First.mp3'))
        $incoming = @($items | ForEach-Object {
            [pscustomobject]@{id=('new-'+$_.title.ToLowerInvariant());stream_url=('/api/library/new-'+$_.title.ToLowerInvariant()+'/stream');path=(Join-Path $migrated ([IO.Path]::GetFileName($_.path)));title=$_.title;artist='Unknown Artist';addedto=[DateTime]::UtcNow.ToString('o')}
        })
        $restored = @(Sync-MusicServerLibraryIndex -Config $target -Items $incoming)
        $restored[0].import_order | Should Be $original[0].import_order
        $restored[1].import_order | Should Be $original[1].import_order
        $restored[0].addedto | Should Be $original[0].addedto
        $restored[0].artist | Should Be 'Singer A'
        $restored[1].duration | Should Be 180
        $restored[0].id | Should Be 'new-first'
        $restored[0].library_id | Should Be 'new-first'
        $restored[0].stream_url | Should Be '/api/library/new-first/stream'
    }

    It 'adds new songs after existing songs and performs no write for unchanged scans' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $before = Get-MusicServerSqliteInvocationCount
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        ((Get-MusicServerSqliteInvocationCount) - $before) | Should Be 1
        $third = Join-Path $fixture.Config.MusicDir 'Third.mp3'
        [IO.File]::WriteAllText($third, 'third recording')
        $all = @($items) + [pscustomobject]@{path=$third;title='Third';artist='Singer C';addedto='1990-01-01T00:00:00Z'}
        $result = @(Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $all)
        $result[2].import_order | Should Be 3
        $result[2].addedto | Should Not Be '1990-01-01T00:00:00Z'
    }

    It 'exports adjacent lyrics and lyric folders without private files or absolute paths' {
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir 'First.lrc'), '[00:01]lyric')
        [IO.Directory]::CreateDirectory((Join-Path $fixture.Config.MusicDir 'Lyrics')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir 'Lyrics\Second.lrc'), '[00:01]second lyric')
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir 'cookies.txt'), 'secret')
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir 'state.db'), 'private database')
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $path = Export-MusicServerLibrary -Config $fixture.Config
        $zip = [IO.Compression.ZipFile]::OpenRead($path)
        try {
            @($zip.Entries).Count | Should Be 5
            ($zip.Entries.FullName -join ',') | Should Not Match 'cookies|state.db'
            $reader = New-Object IO.StreamReader($zip.GetEntry('.musicserver-library.json').Open())
            try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $json | Should Not Match ([regex]::Escape($fixture.Root))
            $json | Should Not Match 'library_id|library_relative_path'
            $json | Should Match 'Singer A'
        } finally { $zip.Dispose() }
    }

    It 'rejects changed recordings without partially restoring metadata' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'Changed'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $migrated)
        [IO.File]::WriteAllText((Join-Path $migrated 'Second.mp3'), 'a different recording')
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        { Import-MusicServerLibraryManifest -Config $target } | Should Throw 'LIBRARY_CONTENT_MISMATCH'
        (Get-MusicServerLibraryIndex -Config $target).Count | Should Be 0
        (Get-MusicServerLibraryIndex -Config $fixture.Config).Count | Should Be 2
        Get-AppSettingDb -Key 'recommendation_library_pending' | Should BeNullOrEmpty
    }

    It 'rejects relative path traversal before any SQLite write' {
        $manifest = @{schema=1;tracks=@(@{relative_path='../outside.mp3';size=1;sha256=('a'*64);import_order=1;imported_at='2024-01-01T00:00:00Z';metadata=@{title='evil'}})}
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir '.musicserver-library.json'), (ConvertTo-Json $manifest -Depth 8))
        { Import-MusicServerLibraryManifest -Config $fixture.Config } | Should Throw 'INVALID_LIBRARY_RELATIVE_PATH'
        (Get-MusicServerLibraryIndex -Config $fixture.Config).Count | Should Be 0
    }

    It 'does not recreate unavailable custom libraries or erase state on empty scans' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @() | Out-Null
        (Get-MusicServerLibraryIndex -Config $fixture.Config).Count | Should Be 2
        $missing = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $missing.MusicDir = Join-Path $fixture.Root 'offline-drive'
        { Export-MusicServerLibrary -Config $missing } | Should Throw 'LIBRARY_UNAVAILABLE'
        [IO.Directory]::Exists($missing.MusicDir) | Should Be $false
    }

    It 'restores exact recording credits and likes without creating wanted downloads or duplicate feedback' {
        $track = New-CanonicalTrack -TrackId 'netease:123456' -Title 'First' -Artist 'Singer A,Singer B' -Album 'Exact album' -Duration 245 -ReleaseYear 2020 -Identifiers @([pscustomobject]@{type='netease';value='123456'}) -LocalSongId ('file:'+$first) -Status LOCAL
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-LikeTrackTransactionDb -TrackId $track.id -Source fixture | Out-Null
        $items[0] | Add-Member -NotePropertyName raw_artist -NotePropertyValue 'Singer A' -Force
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'ExactIdentity'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome (Join-Path $fixture.Root 'new-device-home')
        $target.MusicDir = $migrated
        Initialize-MusicServerDatabase -DbPath (Join-Path $target.StateDir 'musicserver.db') -SqliteExe $target.Sqlite
        Initialize-MusicServerSchema
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        Import-MusicServerLibraryManifest -Config $target | Out-Null
        $count = @(Invoke-MusicServerSqlJson -Query "SELECT * FROM recommendation_feedback WHERE source='library_import';").Count
        $count | Should Be 1
        (Import-MusicServerLibraryManifest -Config $target).already_imported | Should Be $true
        @(Invoke-MusicServerSqlJson -Query "SELECT * FROM recommendation_feedback WHERE source='library_import';").Count | Should Be $count
        $restored = Get-CanonicalTrackDb -TrackId 'netease:123456'
        $restored.artist | Should Be 'Singer A,Singer B'
        $restored.local_song_id | Should Be ('file:'+(Join-Path $migrated 'First.mp3'))
        $restored.status | Should Be 'LOCAL'
        $restored.identifiers[0].value | Should Be '123456'
        @(Invoke-MusicServerSqlJson -Query 'SELECT * FROM wanted_queue;').Count | Should Be 0
        (Get-TrackPreferenceMapDb)['netease:123456'] | Should Be 'LIKE'
        $snapshot = @(Get-MusicServerLibrarySnapshot -Config $target | Where-Object title -eq 'First')[0]
        $snapshot.artist | Should Be 'Singer A,Singer B'
        $snapshot.raw_artist | Should Be 'Singer A'
        $snapshot.album | Should Be 'Exact album'
        $snapshot.duration | Should Be 245
        $snapshot.year | Should Be 2020
        $snapshot.canonical_track_id | Should Be $track.id
        $snapshot.track_id | Should Be $track.id
        $snapshot.liked | Should Be $true
        $restored.artist = 'Singer A,Singer B,Singer C'
        Save-CanonicalTrackDb -Track $restored | Out-Null
        $currentId = Get-MusicServerLocalIdentity -File (Join-Path $migrated 'First.mp3')
        $warm = @(Sync-MusicServerLibraryIndex -Config $target -Items @([pscustomobject]@{id=$currentId;path=(Join-Path $migrated 'First.mp3');title='First';artist='Unknown Artist';duration=0;year=0}))[0]
        $warm.artist | Should Be 'Singer A,Singer B,Singer C'
        (Invoke-UnlikeTrackTransactionDb -TrackId $track.id -Source fixture).liked | Should Be $false
        $snapshot = @(Get-MusicServerLibrarySnapshot -Config $target | Where-Object title -eq 'First')[0]
        $snapshot.artist | Should Be 'Singer A,Singer B,Singer C'
        $snapshot.liked | Should Be $false
        $restored.artist = '[Unknown Artist]'
        Save-CanonicalTrackDb -Track $restored | Out-Null
        @(Get-MusicServerLibrarySnapshot -Config $target | Where-Object title -eq 'First')[0].artist | Should Not Match 'Unknown Artist'
    }

    It 'preserves active downloader ownership while restoring library order and metadata' {
        $track = New-CanonicalTrack -TrackId 'netease:654321' -Title 'First' -Artist 'Singer A' -Identifiers @([pscustomobject]@{type='netease';value='654321'}) -LocalSongId ('file:'+$first) -Status LOCAL
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-LikeTrackTransactionDb -TrackId $track.id -Source fixture | Out-Null
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'ActiveWorker'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO wanted_queue(track_id,state,claimed_by,lease_expires_epoch,revision,created_at,updated_at) VALUES(@id,'DOWNLOADING','worker-fixture',@lease,12,@now,@now); UPDATE canonical_tracks SET status='DOWNLOADING' WHERE id=@id;" -Params @{id=$track.id;lease=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+600);now=(Get-NowIso)}
        Import-MusicServerLibraryManifest -Config $target | Out-Null
        $active = @(Invoke-MusicServerSqlJson -Query "SELECT * FROM wanted_queue WHERE track_id='netease:654321';")[0]
        $active.state | Should Be 'DOWNLOADING'
        $active.claimed_by | Should Be 'worker-fixture'
        $active.revision | Should Be 12
        $canonical = Get-CanonicalTrackDb -TrackId $track.id
        $canonical.status | Should Be 'DOWNLOADING'
        $canonical.local_song_id | Should Be ('file:'+$first)
        (Get-MusicServerLibraryIndex -Config $target).Count | Should Be 2
        ((Get-MusicServerLibraryIndex -Config $target)['first.mp3'].metadata_json | ConvertFrom-Json).artist | Should Be 'Singer A'
    }

    It 'marks recommendation invalidation with a revision bound to the selected library' {
        $firstPending = Set-MusicServerRecommendationLibraryPending -Config $fixture.Config
        $nextPending = Set-MusicServerRecommendationLibraryPending -Config $fixture.Config
        $nextPending.revision | Should Not Be $firstPending.revision
        $persisted = Get-AppSettingDb -Key 'recommendation_library_pending' | ConvertFrom-Json
        $persisted.revision | Should Be $nextPending.revision
        $persisted.path_key | Should Be (Get-MusicServerPathKey -Path $fixture.Config.MusicDir)
    }

    It 'returns playable indexed snapshots without rescanning, resolving or hashing audio' {
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir 'First.lrc'),'[00:01]local lyric')
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        Mock Get-MusicServerLibraryAudioFiles -ModuleName MusicServer.Library { throw 'unexpected scan' }
        Mock Get-MusicServerLibraryStreamHash -ModuleName MusicServer.Library { throw 'unexpected hash' }
        $before = Get-MusicServerSqliteInvocationCount
        $snapshot = @(Get-MusicServerLibrarySnapshot -Config $fixture.Config)
        ((Get-MusicServerSqliteInvocationCount)-$before) | Should Be 2
        $snapshot.Count | Should Be 2
        $snapshot[0].id | Should Be 'old-first'
        $snapshot[0].stream_url | Should Be '/api/library/old-first/stream'
        $snapshot[0].has_local_lyrics | Should Be $true
        $snapshot[1].has_local_lyrics | Should Be $false
        [IO.File]::Delete($second)
        @(Get-MusicServerLibrarySnapshot -Config $fixture.Config).Count | Should Be 1
    }

    It 'resolves indexed media IDs with one lookup and preserves original path spelling after import' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        Mock Get-MusicServerLibraryAudioFiles -ModuleName MusicServer.Library { throw 'unexpected scan' }
        $before = Get-MusicServerSqliteInvocationCount
        Get-MusicServerLibraryFileById -Config $fixture.Config -Id 'old-first' | Should Be $first
        ((Get-MusicServerSqliteInvocationCount)-$before) | Should Be 1
        $relative = 'First.mp3'
        Invoke-MusicServerParamNonQuery -Template "UPDATE library_tracks SET metadata_json=@metadata WHERE relative_path='first.mp3';" -Params @{metadata=('{"title":"First","library_relative_path":"'+$relative+'"}')}
        $currentId = Get-MusicServerLocalIdentity -File $first
        Get-MusicServerLibraryFileById -Config $fixture.Config -Id $currentId | Should Be $first
        Get-MusicServerLibraryFileById -Config $fixture.Config -Id 'old-first' | Should BeNullOrEmpty
        [IO.File]::Delete($first)
        Get-MusicServerLibraryFileById -Config $fixture.Config -Id $currentId | Should BeNullOrEmpty
    }

    It 'uses a job-owned export stage and cleans it when copying fails' {
        $jobId = [guid]::NewGuid().ToString('N')
        $part = Join-Path $fixture.Config.OutputDir ('.musicserver-library-export-'+$jobId+'.part')
        { Export-MusicServerLibrary -Config $fixture.Config -JobId $jobId -Progress { throw 'fixture export interrupted' } } | Should Throw 'fixture export interrupted'
        [IO.File]::Exists($part) | Should Be $false
        @(Get-ChildItem -LiteralPath $fixture.Config.OutputDir -Filter '*.zip').Count | Should Be 0
        { Export-MusicServerLibrary -Config $fixture.Config -JobId '../invalid' } | Should Throw 'INVALID_LIBRARY_EXPORT_JOB'
    }

    It 'keeps committed manifest metadata and order when an older scan finishes afterwards' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'ImportRace'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        $incoming = @(
            [pscustomobject]@{id='race-first';path=(Join-Path $migrated 'First.mp3');title='Stale first';artist='Unknown Artist';addedto='2030-01-01'},
            [pscustomobject]@{id='race-second';path=(Join-Path $migrated 'Second.mp3');title='Stale second';artist='Unknown Artist';addedto='2020-01-01'}
        )
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        Sync-MusicServerLibraryIndex -Config $target -Items $incoming | Out-Null
        $incoming[0].title = 'Updated fallback'
        $global:MusicServerLibraryRaceOnce = $true
        Mock Get-MusicServerLibraryIndex -ModuleName MusicServer.Library -ParameterFilter { $Config.MusicDir -like '*ImportRace' } {
            param($Config)
            $map = @{}
            foreach($row in @(Invoke-MusicServerParamSql -Template 'SELECT * FROM library_tracks WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config)})){$map[[string]$row.relative_path]=$row}
            if($global:MusicServerLibraryRaceOnce){$global:MusicServerLibraryRaceOnce=$false;Import-MusicServerLibraryManifest -Config $Config | Out-Null}
            return $map
        }
        try { $result = @(Sync-MusicServerLibraryIndex -Config $target -Items $incoming) } finally { Remove-Variable MusicServerLibraryRaceOnce -Scope Global -ErrorAction SilentlyContinue }
        $result[0].title | Should Be 'First'
        $result[0].artist | Should Be 'Singer A'
        $result[0].import_order | Should Be 1
        $result[0].library_id | Should Be 'race-first'
        $result[1].import_order | Should Be 2
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT metadata_json,metadata_source FROM library_tracks WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $target)})
        foreach($row in $rows){$row.metadata_source | Should Be 'manifest';($row.metadata_json | ConvertFrom-Json).artist | Should Not Be 'Unknown Artist'}
    }

    It 'allocates appended import order after another writer commits its new row' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $fourth = Join-Path $fixture.Config.MusicDir 'Fourth.mp3'
        [IO.File]::WriteAllText($fourth,'fourth recording')
        $global:MusicServerLibraryRaceOnce = $true
        # Pester 3 retains a module mock target across Import-Module -Force.
        # Use the current module's function scope for this second interleaving.
        $libraryModule = Get-Module MusicServer.Library
        $originalIndex = & $libraryModule { (Get-Command Get-MusicServerLibraryIndex).ScriptBlock }
        $interleavedIndex = {
            param($Config)
            $map = @{}
            foreach($row in @(Invoke-MusicServerParamSql -Template 'SELECT * FROM library_tracks WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config)})){$map[[string]$row.relative_path]=$row}
            if($global:MusicServerLibraryRaceOnce){
                $global:MusicServerLibraryRaceOnce=$false
                Invoke-MusicServerParamNonQuery -Template "INSERT INTO library_tracks(root_key,relative_path,import_order,imported_at,size,modified_at,metadata_json) VALUES(@root,'third.mp3',3,@now,1,@now,'{}');" -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config);now=(Get-NowIso)}
            }
            return $map
        }
        & $libraryModule { param($body) Set-Item Function:script:Get-MusicServerLibraryIndex -Value $body } $interleavedIndex
        try { $result = @(Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @([pscustomobject]@{id='fourth';path=$fourth;title='Fourth';artist='Singer D'})) } finally {
            & $libraryModule { param($body) Set-Item Function:script:Get-MusicServerLibraryIndex -Value $body } $originalIndex
            Remove-Variable MusicServerLibraryRaceOnce -Scope Global -ErrorAction SilentlyContinue
        }
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT relative_path,import_order FROM library_tracks WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $fixture.Config)})
        @($rows | Where-Object relative_path -eq 'third.mp3').Count | Should Be 1
        ($rows | Where-Object relative_path -eq 'fourth.mp3').import_order | Should Be 4
        $result[0].import_order | Should Be 4
        @($rows | Group-Object import_order | Where-Object Count -gt 1).Count | Should Be 0
    }

    It 'fails export before publishing an archive when exact identity state cannot be read' {
        Mock Get-CanonicalLocalTrackMapDb -ModuleName MusicServer.Library { throw 'fixture identity SQLite failure' }
        { Export-MusicServerLibrary -Config $fixture.Config } | Should Throw 'fixture identity SQLite failure'
        @(Get-ChildItem -LiteralPath $fixture.Config.OutputDir -Filter '*.zip').Count | Should Be 0
    }

    It 'commits recommendation invalidation with the import receipt and preserves it on restart' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'PendingRecovery'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        $result = Import-MusicServerLibraryManifest -Config $target
        $pending = Get-AppSettingDb -Key 'recommendation_library_pending' | ConvertFrom-Json
        $pending.revision | Should Be $result.recommendation_revision
        $pending.path_key | Should Be (Get-MusicServerPathKey -Path $target.MusicDir)
        (Import-MusicServerLibraryManifest -Config $target).already_imported | Should Be $true
        (Get-AppSettingDb -Key 'recommendation_library_pending' | ConvertFrom-Json).revision | Should Be $pending.revision
    }

    It 'rolls back recommendation invalidation and the receipt when the import transaction fails' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'PendingRollback'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        Mock Invoke-MusicServerSqlNonQuery -ModuleName MusicServer.Library {
            param($Query)
            if ($Query -match '^BEGIN IMMEDIATE') { $Query = $Query.Replace('COMMIT;','INSERT INTO fixture_missing_import_table VALUES(1); COMMIT;') }
            Invoke-MusicServerSqliteScript -Sql $Query | Out-Null
        }
        { Import-MusicServerLibraryManifest -Config $target } | Should Throw
        Get-AppSettingDb -Key 'recommendation_library_pending' | Should BeNullOrEmpty
        @(Invoke-MusicServerParamSql -Template 'SELECT * FROM library_imports WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $target)}).Count | Should Be 0
        (Get-MusicServerLibraryIndex -Config $target).Count | Should Be 0
    }

    It 'resequences an extra song committed after manifest validation but before its import transaction' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $migrated = Join-Path $fixture.Root 'ImportExtraRace'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
        $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $target.MusicDir = $migrated
        [IO.File]::WriteAllText((Join-Path $migrated 'Third.mp3'),'third recording')
        Set-AppSettingDb -Key 'music_library_path' -Value $migrated
        $global:MusicServerLibraryRaceRoot = Get-MusicServerLibraryRootKey -Config $target
        $libraryModule = Get-Module MusicServer.Library
        $originalWrite = & $libraryModule { (Get-Command Invoke-MusicServerSqlNonQuery).ScriptBlock }
        $interleavedWrite = {
            param($Query)
            if ($Query -match '^BEGIN IMMEDIATE') {
                Invoke-MusicServerParamNonQuery -Template "INSERT INTO library_tracks(root_key,relative_path,import_order,imported_at,size,modified_at,metadata_json) VALUES(@root,'third.mp3',1,@now,15,@now,'{}');" -Params @{root=$global:MusicServerLibraryRaceRoot;now=(Get-NowIso)}
            }
            Invoke-MusicServerSqliteScript -Sql $Query | Out-Null
        }
        & $libraryModule { param($body) Set-Item Function:script:Invoke-MusicServerSqlNonQuery -Value $body } $interleavedWrite
        try { Import-MusicServerLibraryManifest -Config $target | Out-Null } finally {
            & $libraryModule { param($body) Remove-Item Function:script:Invoke-MusicServerSqlNonQuery } $originalWrite
            Remove-Variable MusicServerLibraryRaceRoot -Scope Global -ErrorAction SilentlyContinue
        }
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT relative_path,import_order FROM library_tracks WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $target)})
        ($rows | Where-Object relative_path -eq 'third.mp3').import_order | Should Be 3
        @($rows | Group-Object import_order | Where-Object Count -gt 1).Count | Should Be 0
    }

    It 'does not supersede recommendation scope when the selected library changes during import' {
        $track = New-CanonicalTrack -TrackId 'netease:246810' -Title 'First' -Artist 'Singer A' -Identifiers @([pscustomobject]@{type='netease';value='246810'}) -LocalSongId ('file:'+$first) -Status LOCAL
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-LikeTrackTransactionDb -TrackId $track.id -Source fixture | Out-Null
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $zip = Export-MusicServerLibrary -Config $fixture.Config
        $nextRoot = Join-Path $fixture.Root 'NewestLibrary'
        [IO.Directory]::CreateDirectory($nextRoot) | Out-Null
        $nextFile = Join-Path $nextRoot 'First.mp3'
        [IO.File]::WriteAllText($nextFile,'active recording')
        $track.local_song_id = 'file:'+$nextFile
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO recommendation_feedback(track_id,feedback_type,source,value,created_at) VALUES(@id,'DISLIKE','fixture','true',@now);" -Params @{id=$track.id;now=(Get-NowIso)}
        $canonicalBefore = Get-CanonicalTrackDb -TrackId $track.id
        $libraryModule = Get-Module MusicServer.Library
        foreach($withPending in @($true,$false)) {
            $migrated = Join-Path $fixture.Root ('OldImport-'+$withPending)
            [IO.Compression.ZipFile]::ExtractToDirectory($zip,$migrated)
            $target = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
            $target.MusicDir = $migrated
            Set-AppSettingDb -Key 'music_library_path' -Value $migrated
            Remove-AppSettingDb -Key 'recommendation_library_pending'
            $global:MusicServerLibrarySwitchConfig = New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
            $global:MusicServerLibrarySwitchConfig.MusicDir = $nextRoot
            $global:MusicServerLibrarySwitchPending = $withPending
            $interleavedWrite = {
                param($Query)
                if($Query -match '^BEGIN IMMEDIATE'){
                    Set-AppSettingDb -Key 'music_library_path' -Value $global:MusicServerLibrarySwitchConfig.MusicDir
                    if($global:MusicServerLibrarySwitchPending){Set-MusicServerRecommendationLibraryPending -Config $global:MusicServerLibrarySwitchConfig | Out-Null}
                    else {Remove-AppSettingDb -Key 'recommendation_library_pending'}
                }
                Invoke-MusicServerSqliteScript -Sql $Query | Out-Null
            }
            & $libraryModule { param($body) Set-Item Function:script:Invoke-MusicServerSqlNonQuery -Value $body } $interleavedWrite
            try {{Import-MusicServerLibraryManifest -Config $target} | Should Throw 'LIBRARY_CHANGED'}finally{
                & $libraryModule { Remove-Item Function:script:Invoke-MusicServerSqlNonQuery }
                Remove-Variable MusicServerLibrarySwitchConfig,MusicServerLibrarySwitchPending -Scope Global -ErrorAction SilentlyContinue
            }
            (Get-MusicServerLibraryIndex -Config $target).Count | Should Be 0
            @(Invoke-MusicServerParamSql -Template 'SELECT * FROM library_imports WHERE root_key=@root;' -Params @{root=(Get-MusicServerLibraryRootKey -Config $target)}).Count | Should Be 0
            $canonicalAfter = Get-CanonicalTrackDb -TrackId $track.id
            $canonicalAfter.local_song_id | Should Be ('file:'+$nextFile)
            $canonicalAfter.revision | Should Be $canonicalBefore.revision
            (Get-TrackPreferenceMapDb)[$track.id] | Should Be 'DISLIKE'
            if($withPending){(Get-AppSettingDb -Key 'recommendation_library_pending' | ConvertFrom-Json).path_key | Should Be (Get-MusicServerPathKey -Path $nextRoot)}
            else {Get-AppSettingDb -Key 'recommendation_library_pending' | Should BeNullOrEmpty}
        }
    }

    It 'allocates a new batch by observed import time even when older songs are already indexed' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items $items | Out-Null
        $early = Join-Path $fixture.Config.MusicDir 'Z-new.mp3'
        $late = Join-Path $fixture.Config.MusicDir 'A-new.mp3'
        [IO.File]::WriteAllText($early,'early recording')
        [IO.File]::WriteAllText($late,'late recording')
        $result = @(Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @(
            [pscustomobject]@{id='late';path=$late;title='Late';addedto='2026-10-08T12:00:00Z'},
            $items[1],
            [pscustomobject]@{id='early';path=$early;title='Early';addedto='2026-10-08T11:00:00Z'},
            $items[0]
        ))
        $result[0].title | Should Be 'Late'
        $result[0].import_order | Should Be 4
        $result[2].import_order | Should Be 3
        $result[1].import_order | Should Be 2
        $result[3].import_order | Should Be 1
    }
}
