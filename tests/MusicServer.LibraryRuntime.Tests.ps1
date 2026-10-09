$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'Portable library through the live desktop services' {
    BeforeEach {
        $script:fixture=New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Library.psm1') -Force -DisableNameChecking
        $script:oldDiagnostics=$env:MUSICSERVER_DIAGNOSTICS
        $env:MUSICSERVER_DIAGNOSTICS='1'
        $script:first=Join-Path $fixture.Config.MusicDir 'First.mp3'
        $script:second=Join-Path $fixture.Config.MusicDir 'Second.mp3'
        [IO.File]::WriteAllText($first,'first recording')
        [IO.File]::WriteAllText($second,'second recording')
    }
    AfterEach {
        $env:MUSICSERVER_DIAGNOSTICS=$script:oldDiagnostics
        Remove-MusicServerRuntimeFixture -Fixture $fixture
    }
    It 'keeps health and settings responsive while a cold scan runs and coalesces another request' {
        $path=Join-Path $fixture.Root 'start_musicserver_ui.ps1'
        $source=[IO.File]::ReadAllText($path)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UiLibrary'},$false)
        $body='{ [IO.File]::WriteAllText((Join-Path $Config.AppHome ''scan.started''),''yes''); Start-Sleep -Milliseconds 3500;' + $fn.Body.Extent.Text.Substring(1)
        $source=$source.Substring(0,$fn.Body.Extent.StartOffset)+$body+$source.Substring($fn.Body.Extent.EndOffset)
        [IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
        Start-MusicServerFixtureServices -Fixture $fixture -WithUi
        $url='http://127.0.0.1:'+$fixture.UiPort
        $request=[Net.HttpWebRequest]::Create($url+'/api/library?refresh=1');$request.Timeout=15000
        $pending=$request.BeginGetResponse($null,$null)
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while(-not [IO.File]::Exists((Join-Path $fixture.Root 'scan.started')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
        [IO.File]::Exists((Join-Path $fixture.Root 'scan.started')) | Should Be $true
        $clock=[Diagnostics.Stopwatch]::StartNew()
        (Invoke-RestMethod ($url+'/health') -TimeoutSec 2).status | Should Be 'ok'
        (Invoke-RestMethod ($url+'/api/settings/display-mode') -TimeoutSec 2).mode | Should Be 'raw'
        (Invoke-RestMethod ($url+'/api/library') -TimeoutSec 2).loading | Should Be $true
        ($clock.ElapsedMilliseconds -lt 1500) | Should Be $true
        $response=$request.EndGetResponse($pending)
        try { $reader=New-Object IO.StreamReader($response.GetResponseStream());try{$value=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()} }finally{$response.Dispose()}
        @($value.items).Count | Should Be 2
        $firstResponse=Invoke-WebRequest ('http://127.0.0.1:'+$fixture.ApiPort+'/api/library') -UseBasicParsing -TimeoutSec 10
        $warm=Invoke-WebRequest ('http://127.0.0.1:'+$fixture.ApiPort+'/api/library') -UseBasicParsing -TimeoutSec 2
        [int]$warm.Headers['X-MusicServer-State-Sqlite-Calls'] | Should Be 0
    }
    It 'keeps the workspace usable and waits for migration before publishing its first scanned library' {
        Start-MusicServerFixtureServices -Fixture $fixture -WithUi
        Set-AppSettingDb -Key 'library_manifest_pending' -Value 'fixture-import-in-progress'
        $url='http://127.0.0.1:'+$fixture.UiPort
        $clock=[Diagnostics.Stopwatch]::StartNew()
        (Invoke-RestMethod ($url+'/api/library') -TimeoutSec 2).loading | Should Be $true
        (Invoke-RestMethod ($url+'/health') -TimeoutSec 2).status | Should Be 'ok'
        (Invoke-RestMethod ($url+'/api/settings/display-mode') -TimeoutSec 2).mode | Should Be 'raw'
        ($clock.ElapsedMilliseconds -lt 1500) | Should Be $true
        (Invoke-RestMethod ($url+'/api/library') -TimeoutSec 2).loading | Should Be $true
        Remove-AppSettingDb -Key 'library_manifest_pending'
        $result=Invoke-RestMethod ($url+'/api/library?refresh=1') -TimeoutSec 15
        @($result.items).Count | Should Be 2
    }
    It 'automatically restores an exported library after selecting its extracted folder and provides an asynchronous export' {
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @(
            [pscustomobject]@{id='na-old1';path=$first;title='First song';artist='Singer A';addedto='2020-01-01'},
            [pscustomobject]@{id='na-old2';path=$second;title='Second song';artist='Singer B';addedto='2020-01-02'}
        ) | Out-Null
        $zip=Export-MusicServerLibrary -Config $fixture.Config
        $target=Join-Path $fixture.Root 'transferred'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$target)
        Set-AppSettingDb -Key 'music_library_path' -Value $target
        Start-MusicServerFixtureServices -Fixture $fixture -WithUi
        $api='http://127.0.0.1:'+$fixture.ApiPort
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        do { $status=Invoke-RestMethod ($api+'/api/maintenance') -TimeoutSec 5;$job=@($status.jobs | Where-Object {$_.operation -eq 'library-import'}) | Select-Object -First 1;if($job.state -ne 'RUNNING' -and $job){break};Start-Sleep -Milliseconds 200 }while([DateTime]::UtcNow -lt $deadline)
        $job.state | Should Be 'DONE'
        $library=Invoke-RestMethod ('http://127.0.0.1:'+$fixture.UiPort+'/api/library?refresh=1') -TimeoutSec 15
        @($library.items).Count | Should Be 2
        ($library.items | Where-Object {$_.title -eq 'Second song'}).import_order | Should Be 2
        foreach($item in $library.items){$item.library_id | Should Be $item.id; $item.stream_url | Should Be ('/api/library/'+$item.id+'/stream')}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $started=Invoke-RestMethod ($api+'/api/maintenance') -Method POST -ContentType 'application/json' -Body '{"operation":"library-export"}' -TimeoutSec 3
        ($clock.ElapsedMilliseconds -lt 1500) | Should Be $true
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        do { $status=Invoke-RestMethod ($api+'/api/maintenance') -TimeoutSec 5;$job=@($status.jobs | Where-Object {$_.id -eq $started.id}) | Select-Object -First 1;if($job.state -ne 'RUNNING'){break};Start-Sleep -Milliseconds 200 }while([DateTime]::UtcNow -lt $deadline)
        $job.state | Should Be 'DONE'
        [IO.File]::Exists($job.result_path) | Should Be $true
        Get-AppSettingDb -Key 'library_manifest_pending' | Should BeNullOrEmpty
        Get-AppSettingDb -Key 'recommendation_library_pending' | Should Not BeNullOrEmpty
    }

    It 'deletes a migrated exact file binding while keeping preferences and active worker ownership recoverable' {
        $track=New-CanonicalTrack -TrackId 'netease:345678' -Title 'First song' -Artist 'Singer A' -Identifiers @([pscustomobject]@{type='netease';value='345678'}) -LocalSongId ('file:'+$first) -Status LOCAL
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-LikeTrackTransactionDb -TrackId $track.id -Source fixture | Out-Null
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO wanted_queue(track_id,state,revision,created_at,updated_at) VALUES(@id,'LOCAL',4,@now,@now);" -Params @{id=$track.id;now=(Get-NowIso)}
        Sync-MusicServerLibraryIndex -Config $fixture.Config -Items @([pscustomobject]@{id=(Get-MusicServerLocalIdentity -File $first);path=$first;title='First song';artist='Singer A';addedto='2020-01-01'}) | Out-Null
        $zip=Export-MusicServerLibrary -Config $fixture.Config
        $target=Join-Path $fixture.Root 'delete-migrated'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$target)
        $targetConfig=New-MusicServerConfig -Root $ProjectRoot -AppHome $fixture.Root
        $targetConfig.MusicDir=$target
        Set-AppSettingDb -Key 'music_library_path' -Value $target
        Import-MusicServerLibraryManifest -Config $targetConfig | Out-Null
        $targetFirst=Join-Path $target 'First.mp3'
        $activeFile=Join-Path $target 'Second.mp3'
        $active=New-CanonicalTrack -TrackId 'netease:987654' -Title 'Second song' -Artist 'Singer B' -LocalSongId ('file:'+$activeFile) -Status DOWNLOADING
        Save-CanonicalTrackDb -Track $active | Out-Null
        Invoke-MusicServerParamNonQuery -Template "INSERT INTO wanted_queue(track_id,state,claimed_by,lease_expires_epoch,revision,created_at,updated_at) VALUES(@id,'DOWNLOADING','fixture-owner',@lease,9,@now,@now);" -Params @{id=$active.id;lease=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+600);now=(Get-NowIso)}
        Start-MusicServerFixtureServices -Fixture $fixture
        $api='http://127.0.0.1:'+$fixture.ApiPort
        $deleted=Invoke-RestMethod ($api+'/api/library/'+(Get-MusicServerLocalIdentity -File $targetFirst)) -Method DELETE -TimeoutSec 10
        $deleted.deleted | Should Be $true
        [IO.File]::Exists($targetFirst) | Should Be $false
        $after=Get-CanonicalTrackDb -TrackId $track.id
        $after.status | Should Be 'REMOTE'
        $after.local_song_id | Should BeNullOrEmpty
        (Get-TrackPreferenceMapDb)[$track.id] | Should Be 'LIKE'
        Get-WantedItemDb -TrackId $track.id | Should BeNullOrEmpty
        (Invoke-LikeTrackTransactionDb -TrackId $track.id -Source fixture).action | Should Be 'QUEUED'
        (Invoke-RestMethod ($api+'/api/library/'+(Get-MusicServerLocalIdentity -File $activeFile)) -Method DELETE -TimeoutSec 10).deleted | Should Be $true
        $lease=Get-WantedItemDb -TrackId $active.id
        $lease.state | Should Be 'DOWNLOADING'
        $lease.claimed_by | Should Be 'fixture-owner'
        $lease.revision | Should Be 9
        (Get-CanonicalTrackDb -TrackId $active.id).status | Should Be 'DOWNLOADING'
        (Get-CanonicalTrackDb -TrackId $active.id).local_song_id | Should Be ('file:'+$activeFile)
    }
}
