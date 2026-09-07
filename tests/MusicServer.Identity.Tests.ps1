$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'Runtime content identity' {
    BeforeEach {
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Identity.psm1') -Force
        $fixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $fixture }

    It 'is independent of location and user state' {
        $before = Get-MusicServerBuildIdentity -Root $fixture.Root
        $before | Should Match '^musicserver-[0-9a-f]{64}$'
        $copy = Join-Path $TestDrive 'another installation'
        Copy-Item -LiteralPath $fixture.Root -Destination $copy -Recurse
        (Get-MusicServerBuildIdentity -Root $copy) | Should Be $before
        Set-Content (Join-Path $copy 'user-config.json') 'private user state'
        (Get-MusicServerBuildIdentity -Root $copy) | Should Be $before
    }

    It 'changes for runtime edits and missing files' {
        $before = Get-MusicServerBuildIdentity -Root $fixture.Root
        Add-Content (Join-Path $fixture.Root 'web/styles.css') '/* next version */'
        $after = Get-MusicServerBuildIdentity -Root $fixture.Root
        $after | Should Not Be $before
        Remove-Item (Join-Path $fixture.Root 'web/styles.css')
        (Get-MusicServerBuildIdentity -Root $fixture.Root) | Should Not Be $after
    }

    It 'serves matching startup identities and does not relabel an old process after edits' {
        Start-MusicServerFixtureServices -Fixture $fixture -WithUi
        $expected = Get-MusicServerBuildIdentity -Root $fixture.Root
        $healthUrl = "http://127.0.0.1:$($fixture.ApiPort)/health"
        $jsUrl = "http://127.0.0.1:$($fixture.UiPort)/app.js"
        (Invoke-RestMethod $healthUrl).build | Should Be $expected
        (Invoke-WebRequest $jsUrl -UseBasicParsing).Content | Should Match $expected
        Add-Content (Join-Path $fixture.Root 'web/styles.css') '/* upgraded on disk */'
        (Get-MusicServerBuildIdentity -Root $fixture.Root) | Should Not Be $expected
        (Invoke-RestMethod $healthUrl).build | Should Be $expected
        (Invoke-WebRequest $jsUrl -UseBasicParsing).Content | Should Match $expected
    }
}
