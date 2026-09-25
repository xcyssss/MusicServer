$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'First-use API on an empty installed runtime' {
    BeforeAll {
        $script:GuideRuntime = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Start-MusicServerFixtureServices -Fixture $script:GuideRuntime -WithUi
        $script:GuideBase = "http://127.0.0.1:$($script:GuideRuntime.UiPort)"
    }
    AfterAll { if ($script:GuideRuntime) { Remove-MusicServerRuntimeFixture -Fixture $script:GuideRuntime } }

    It 'prepares an empty day over the real UI proxy without starting downloads' {
        $start = Invoke-RestMethod "$script:GuideBase/api/onboarding" -Method Post -ContentType 'application/json' -Body '{}'
        $start.phase | Should Be welcome
        $rows = (Invoke-RestMethod "$script:GuideBase/api/recommendations/today").items
        @($rows).Count | Should Be 14
        @((Invoke-RestMethod "$script:GuideBase/api/wanted").items).Count | Should Be 0
        (Invoke-WebRequest "$script:GuideBase/onboarding.js" -UseBasicParsing).StatusCode | Should Be 200
        (Invoke-WebRequest "$script:GuideBase/management.js" -UseBasicParsing).StatusCode | Should Be 200
        @((Invoke-RestMethod "$script:GuideBase/api/maintenance").components).Count | Should Be 3
    }

    It 'exports a backup asynchronously through the real proxy and exposes its result' {
        $job=Invoke-RestMethod "$script:GuideBase/api/maintenance" -Method Post -ContentType 'application/json' -Body '{"operation":"backup"}'
        $job.id | Should Match '^[a-f0-9]{32}$'
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        do {
            $status=Invoke-RestMethod "$script:GuideBase/api/maintenance"
            $found=@($status.jobs | Where-Object { $_.id -eq $job.id })[0]
            if ($found.state -ne 'RUNNING') { break }
            Start-Sleep -Milliseconds 300
        } while ([DateTime]::UtcNow -lt $deadline)
        $found.state | Should Be DONE
        @($status.backups).Count | Should BeGreaterThan 0
        [IO.File]::Exists((Join-Path $found.result_path 'musicserver.db')) | Should Be $true
    }

    It 'persists preferences and uses the existing atomic like-to-download contract' {
        $id = (Invoke-RestMethod "$script:GuideBase/api/recommendations/today").items[0].track_id
        $like = Invoke-RestMethod "$script:GuideBase/api/tracks/$id/like" -Method Post -ContentType 'application/json' -Body '{}'
        $like.liked | Should Be $true
        $like.wanted.state | Should Be WANTED
        $body = @{phase='download';track_id=$id;dismissed=$true;normalize=$true;auto_lyrics=$false} | ConvertTo-Json -Compress
        Invoke-RestMethod "$script:GuideBase/api/onboarding" -Method Put -ContentType 'application/json' -Body $body | Out-Null
        $saved = Invoke-RestMethod "$script:GuideBase/api/onboarding"
        $saved.track.track_id | Should Be $id
        $saved.dismissed | Should Be $true
        $saved.auto_lyrics | Should Be $false
        (Invoke-RestMethod "$script:GuideBase/api/settings/display-mode").mode | Should Be canonical
    }

    It 'rejects string booleans without changing preferences' {
        $response = Invoke-MusicServerFragmentedRequest -Port $script:GuideRuntime.UiPort -Path '/api/onboarding' -Method PUT -Fragments @('{"normalize":"false"}')
        $response.Status | Should Be 400
        (Invoke-RestMethod "$script:GuideBase/api/settings/display-mode").mode | Should Be canonical
    }
}
