$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Force
# Load the real worker functions without starting its loop or touching host state.
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'wanted_worker.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw $errors[0] }
foreach ($function in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
Describe 'Like download fallback pipeline' {
    BeforeEach {
        $Config=New-MusicServerConfig -Root $ProjectRoot -AppHome (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Initialize-MusicServerState -Config $Config
        Initialize-MusicServerDatabase -DbPath (Join-Path $Config.StateDir 'musicserver.db') -SqliteExe $Config.Sqlite
        Initialize-MusicServerSchema
        $WorkerId='pipeline-test'
        $ActiveQueueStates=@('RESOLVING','DOWNLOADING','VALIDATING')
        Mock Write-WorkerLog {}
        $track=New-CanonicalTrack -Title 'Known Song' -Artist 'Artist' -Duration 200 -Identifiers @([pscustomobject]@{type='netease';value='123'}) -DownloadCandidates @([pscustomobject]@{provider='bilibili_direct';bvid='BVknown';duration=200;priority=70})
        Save-CanonicalTrackDb -Track $track | Out-Null
    }
    It 'does not discard NetEase when the direct Bilibili circuit is open' {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_download' -HttpStatus 412 | Out-Null
        $ranked=@(Resolve-DownloadCandidates -Config $Config -Track $track)
        $ranked.Count | Should Be 1
        $ranked[0].Candidate.provider | Should Be 'netease'
    }
    It 'rejects another NetEase singer even when title and duration are identical' {
        $candidate=New-DownloadCandidate -Provider netease -Title 'Known Song' -Artist 'Someone Else' -Duration 200 -Url 'netease:456'
        Test-DownloadCandidateIdentity -Track $track -Candidate $candidate | Should Be $false
    }
    It 'never searches before trying a known NetEase identity' {
        $track.download_candidates=@()
        Mock Search-BilibiliCandidates { throw 'should not search' } -ModuleName MusicServer.Providers
        $ranked=@(Resolve-DownloadCandidates -Config $Config -Track $track)
        $ranked.Count | Should Be 1
        $ranked[0].Candidate.provider | Should Be 'netease'
        Assert-MockCalled Search-BilibiliCandidates -ModuleName MusicServer.Providers -Times 0 -Exactly -Scope It
    }
    It 'does not use duration as a replacement for evidence of the singer' {
        $candidate=New-DownloadCandidate -Provider bilibili_search -Title 'Known Song' -Artist '' -Duration 200 -Url 'https://www.bilibili.com/video/BVfixture'
        Test-DownloadCandidateIdentity -Track $track -Candidate $candidate | Should Be $false
    }
    It 'requires complete audio decoding even after duration validation passes' {
        Mock Invoke-MusicServerBoundedProcess {
            param($FilePath)
            if ($FilePath -eq $Config.FFprobe) { return [pscustomobject]@{ExitCode=0;Output='200';Error=''} }
            return [pscustomobject]@{ExitCode=1;Output='';Error='corrupt audio'}
        } -ModuleName MusicServer.Providers
        $result=Validate-DownloadedCandidate -Config $Config -Track $track -Path 'corrupt.mp3'
        $result.Valid | Should Be $false
        $result.Reason | Should Be 'AUDIO_DECODE_FAILED'
    }
    It 'uses separate staging paths without deleting a same-named file' {
        $owned=Join-Path $Config.DailyDir "$(Get-SafeDownloadName -Track $track).mp3"
        [IO.File]::WriteAllText($owned,'owned music')
        $first=New-DownloadStagingPath -Config $Config -Track $track
        $second=New-DownloadStagingPath -Config $Config -Track $track
        ($first -ne $second) | Should Be $true
        [IO.File]::ReadAllText($owned) | Should Be 'owned music'
    }
    It 'keeps likes queued without consuming attempts when components are missing' {
        Invoke-LikeTrackTransactionDb -TrackId $track.id | Out-Null
        $MaxItems=5; $DryRun=$false
        $saved=@{}
        foreach ($name in @('PATH','MUSICSERVER_YTDLP','MUSICSERVER_FFMPEG','MUSICSERVER_FFPROBE')) {
            $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
            [Environment]::SetEnvironmentVariable($name,$null,'Process')
        }
        try { Invoke-WorkerPass } finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
        }
        $wanted=Get-WantedItemDb -TrackId $track.id
        $wanted.state | Should Be WANTED
        $wanted.attempt_count | Should Be 0
    }
    It 'advances a real liked and leased queue through one fallback after a dead direct resource' {
        Invoke-LikeTrackTransactionDb -TrackId $track.id | Out-Null
        $claim=Claim-WantedItemDb -TrackId $track.id -WorkerId $WorkerId
        $claim.Success | Should Be $true
        $wanted=Get-WantedItemDb -TrackId $track.id
        Mock Find-LocalTrack { $null }
        Mock Resolve-DownloadCandidates {
            param($Config,$Track,[switch]$SearchFallbackOnly)
            $url=if ($SearchFallbackOnly) { 'fallback' } else { 'dead' }
            @([pscustomobject]@{Candidate=(New-DownloadCandidate -Provider 'bilibili_direct' -Url $url -Title 'Known Song' -Artist Artist -Duration 200);Score=[pscustomobject]@{score=100;identity_confidence=100;duration_diff=0}})
        }
        Mock Invoke-BilibiliDownload { param($Config,$Track,$Candidate) [pscustomobject]@{Success=($Candidate.url -eq 'fallback');Blocked=$false;Error='DOWNLOAD_FAILED';Path='test-audio'} }
        Mock Validate-DownloadedCandidate { [pscustomobject]@{Valid=$true;Reason='OK';Duration=200;DurationDiff=0;AllowedDiff=5} }
        Mock Complete-DownloadedTrack { param($Track,$Wanted) [void](Set-QueueState -Wanted $Wanted -State LOCAL) }
        Process-WantedTrack -Wanted $wanted
        (Get-WantedItemDb -TrackId $track.id).state | Should Be 'LOCAL'
        Assert-MockCalled Resolve-DownloadCandidates -Times 1 -Exactly -Scope It -ParameterFilter { $SearchFallbackOnly }
        Assert-MockCalled Invoke-BilibiliDownload -Times 2 -Exactly -Scope It
        Assert-MockCalled Complete-DownloadedTrack -Times 1 -Exactly -Scope It
    }
    It 'tries a healthy second source after a direct source becomes blocked mid-download' {
        Invoke-LikeTrackTransactionDb -TrackId $track.id | Out-Null
        Claim-WantedItemDb -TrackId $track.id -WorkerId $WorkerId | Out-Null
        $wanted=Get-WantedItemDb -TrackId $track.id
        Mock Find-LocalTrack { $null }
        Mock Resolve-DownloadCandidates {
            @('bilibili_direct','netease') | ForEach-Object {
                [pscustomobject]@{Candidate=(New-DownloadCandidate -Provider $_ -Url $_ -Title 'Known Song' -Artist Artist -Duration 200);Score=[pscustomobject]@{score=100;identity_confidence=100;duration_diff=0}}
            }
        }
        Mock Invoke-BilibiliDownload { [pscustomobject]@{Success=$false;Blocked=$true;Error='HTTP_412';Path=''} }
        Mock Invoke-NeteaseDownload { [pscustomobject]@{Success=$true;Blocked=$false;Error='';Path='test-audio'} }
        Mock Validate-DownloadedCandidate { [pscustomobject]@{Valid=$true;Reason='OK';Duration=200;DurationDiff=0;AllowedDiff=5} }
        Mock Complete-DownloadedTrack { param($Track,$Wanted) [void](Set-QueueState -Wanted $Wanted -State LOCAL) }
        Process-WantedTrack -Wanted $wanted
        (Get-WantedItemDb -TrackId $track.id).state | Should Be 'LOCAL'
        Assert-MockCalled Invoke-NeteaseDownload -Times 1 -Exactly -Scope It
        Assert-MockCalled Resolve-DownloadCandidates -Times 1 -Exactly -Scope It
    }
    It 'stops at the retry budget even when the source remains blocked' {
        Invoke-LikeTrackTransactionDb -TrackId $track.id -MaxAttempts 1 | Out-Null
        Claim-WantedItemDb -TrackId $track.id -WorkerId $WorkerId | Out-Null
        $wanted=Get-WantedItemDb -TrackId $track.id
        Mock Find-LocalTrack { $null }
        Mock Resolve-DownloadCandidates { @() }
        Mock Get-BilibiliBlockedUntil { [DateTime]::UtcNow.AddHours(1).ToString('o') }
        Process-WantedTrack -Wanted $wanted
        (Get-WantedItemDb -TrackId $track.id).state | Should Be 'UNAVAILABLE'
        (Get-WantedItemDb -TrackId $track.id).attempt_count | Should Be 1
    }
    It 'shares cleaned queries and splits collaboration artist hints' {
        $queries=@(Get-SongSearchQueries -Title '《流浪的猫写情诗》' -Artist '音阙诗听×李佳思' -Max 1)
        $queries[0] | Should Be '流浪的猫写情诗 音阙诗听'
    }
    It 'keeps ranked discoveries diverse across all credited singers and deduplicates songs' {
        $pool=@(
            [pscustomobject]@{Title='One';Artist='A'},
            [pscustomobject]@{Title='Two';Artist='A×B'},
            [pscustomobject]@{Title='Three';Artist='C'},
            [pscustomobject]@{Title='One';Artist='A'}
        )
        $selected=@(Select-DiverseRemoteRecommendations -Candidates $pool -Count 5)
        $selected.Count | Should Be 3
        $selected[0].Title | Should Be 'One'
        $selected[1].Title | Should Be 'Three'
        $selected[2].Title | Should Be 'Two'
        @(Select-DiverseRemoteRecommendations -Candidates $pool -Count 0).Count | Should Be 0
    }
}
