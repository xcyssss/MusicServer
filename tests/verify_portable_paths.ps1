param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$LogDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logRoot = [IO.Path]::GetFullPath($LogDirectory)
[IO.Directory]::CreateDirectory($logRoot) | Out-Null
. (Join-Path $PSScriptRoot 'MusicServer.DesktopSmoke.ps1')
Import-Module (Join-Path $root 'MusicServer.Identity.psm1') -Force
$marker = Get-MusicServerBuildIdentity -Root $root
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixture = Join-Path $tempBase ('musicserver-portable-smoke-' + [guid]::NewGuid().ToString('N'))
if (-not $fixture.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $fixture)) {throw 'Unsafe fixture path'}
$appDir = Join-Path $fixture 'Program'
$dataDir = Join-Path $fixture 'Data'
$foreign = @(); $desktop = $null; $disabled = @(); $savedEnv = @{}
$envValues = @{
  MUSICSERVER_APP_HOME=(Join-Path $fixture 'stale-home');
  MUSICSERVER_DISABLE_WORKER='1'; MUSICSERVER_DISABLE_SCHEDULED_TASKS='1'; MUSICSERVER_DISABLE_ARTIST_BACKFILL='1';
  WEBVIEW2_USER_DATA_FOLDER=($fixture+'-webview');
}
$probeListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$probeListener.Start(); $debugPort=$probeListener.LocalEndpoint.Port; $probeListener.Stop()
$envValues.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=$debugPort"
function Assert-FixturePath([string]$Path) {
  $full=[IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $full).StartsWith('musicserver-portable-smoke-')) {throw "Unsafe fixture mutation: $full"}
  if (Test-Path -LiteralPath $full) { if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Fixture is a link'} }
}
function Wait-Pair {
  $deadline=[DateTime]::UtcNow.AddSeconds(75)
  do {
    if ($desktop.HasExited) {throw 'Portable APP exited during startup'}
    $found=Get-MusicServerSmokePair -AppHome $dataDir -BuildMarker $marker -DesktopProcessId $desktop.Id
    if ($found) {return $found}
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Portable APP did not become ready'
}
function Close-Desktop {
  Close-MusicServerSmokeDesktop -Process $desktop
  $script:desktop=$null
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  do {
    $open=$false
    foreach($port in @($pair.UiPort,$pair.ApiPort)) {
      $client=New-Object Net.Sockets.TcpClient
      try {if($client.ConnectAsync('127.0.0.1',$port).Wait(200)){$open=$true}} catch {} finally {$client.Dispose()}
    }
    if(-not $open){return}
    Start-Sleep -Milliseconds 250
  } while([DateTime]::UtcNow -lt $deadline)
  throw 'Owned services survived normal APP close'
}
try {
  foreach($key in $envValues.Keys){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$envValues[$key],'Process')}
  New-Item -ItemType Directory -Path $appDir,$dataDir,(Join-Path $appDir 'resources') -Force | Out-Null
  Copy-Item -LiteralPath $Executable -Destination (Join-Path $appDir 'MusicServer.exe')
  Copy-Item -LiteralPath (Join-Path $root 'src-tauri\resources\runtime') -Destination (Join-Path $appDir 'resources\runtime') -Recurse
  [IO.File]::WriteAllText((Join-Path $appDir 'musicserver.paths.json'),'{"schema":1,"app_home":"../Data"}')
  foreach($port in @(8787,8788,8789,8790,8791,8792)) {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
    try {$listener.Start();$foreign+=,$listener} catch {$listener.Stop()}
  }
  # Only known repository entries are renamed, and every rename is restored below.
  foreach($name in @('start_musicserver_ui.ps1','music_api.ps1','MusicServer.Core.psm1','web')) {
    $source=[IO.Path]::GetFullPath((Join-Path $root $name));$target=$source+'.portable-smoke-disabled'
    if ((Split-Path -Parent $source) -ne $root -or (Test-Path -LiteralPath $target)) {throw 'Unsafe source-runtime isolation'}
    if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Source-runtime entry is a link'}
    Move-Item -LiteralPath $source -Destination $target
    $disabled+=,[pscustomobject]@{Source=$source;Target=$target}
  }
  $desktop=Start-Process -FilePath (Join-Path $appDir 'MusicServer.exe') -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
  $pair=Wait-Pair
  if ($pair.UiPort -in @(8787,8788,8789,8790,8791,8792) -or $pair.ApiPort -in @(8787,8788,8789,8790,8791,8792)) {throw 'APP reused an occupied port'}
  & node (Join-Path $PSScriptRoot 'inspect_portable_desktop.cjs') $debugPort ready (Join-Path $logRoot 'portable-ready.png')
  if($LASTEXITCODE -ne 0){throw 'Desktop visual inspection failed'}
  $libraryDir=Join-Path $dataDir 'Music'
  New-Item -ItemType Directory -Path $libraryDir -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $libraryDir 'portable-fixture.wav'),(New-Object byte[] 4096))
  $body=[Text.Encoding]::UTF8.GetBytes('{"path":"Music"}')
  $set=Invoke-RestMethod -Uri "http://127.0.0.1:$($pair.ApiPort)/api/settings/music-library" -Method Put -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 15
  if (-not $set.accepted -or $set.path -ne $libraryDir) {throw 'Relative library setting failed'}
  Close-Desktop
  $sqlite=Join-Path $dataDir 'tools\sqlite3.exe';$db=Join-Path $dataDir 'DailyMix_data\state\musicserver.db'
  $stored=& $sqlite -readonly $db "SELECT value FROM app_settings WHERE key='music_library_path';"
  if ($stored -ne 'Music') {throw "Music setting was not relative: $stored"}
  & $sqlite $db "CREATE TABLE portable_smoke_history(value TEXT); INSERT INTO portable_smoke_history VALUES('preserved');"
  if($LASTEXITCODE -ne 0){throw 'History fixture initialization failed'}
  $oldFixture=$fixture;$newFixture=$fixture+'-moved'
  Assert-FixturePath $oldFixture;Assert-FixturePath $newFixture
  Move-Item -LiteralPath $oldFixture -Destination $newFixture
  $fixture=$newFixture;$appDir=Join-Path $fixture 'Program';$dataDir=Join-Path $fixture 'Data'
  $desktop=Start-Process -FilePath (Join-Path $appDir 'MusicServer.exe') -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
  $pair=Wait-Pair
  $settings=Invoke-RestMethod -Uri "http://127.0.0.1:$($pair.ApiPort)/api/settings/music-library" -TimeoutSec 15
  if ($settings.path -ne (Join-Path $dataDir 'Music') -or -not $settings.available) {throw 'Moved music directory was not restored'}
  Close-Desktop
  $sqlite=Join-Path $dataDir 'tools\sqlite3.exe';$db=Join-Path $dataDir 'DailyMix_data\state\musicserver.db'
  $history=& $sqlite -readonly $db 'SELECT value FROM portable_smoke_history;'
  if ($history -ne 'preserved' -or (Test-Path -LiteralPath $oldFixture)) {throw 'Moving the parent lost data or recreated the old home'}
  [IO.File]::WriteAllText((Join-Path $appDir 'musicserver.paths.json'),'{"schema":1,"app_home":"../Missing"}')
  $desktop=Start-Process -FilePath (Join-Path $appDir 'MusicServer.exe') -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
  & node (Join-Path $PSScriptRoot 'inspect_portable_desktop.cjs') $debugPort error (Join-Path $logRoot 'missing-home.png')
  if($LASTEXITCODE -ne 0){throw 'Missing-home screen inspection failed'}
  Close-Desktop
  if (Test-Path -LiteralPath (Join-Path $fixture 'Missing')) {throw 'Missing home was silently recreated'}
  [ordered]@{Passed=$true;Build=$marker;ParentMove=$true;HistoryPreserved=$true;RelativeLibrary=$true;MissingHomeBlocked=$true;SourceRuntimeDisabled=$true;FixedPortsOccupied=$true;NormalClose=$true;Fixture=$fixture} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'portable-smoke.json') -Encoding UTF8
  Write-Output 'PASS: actual portable APP, moved parent, preserved history, relative library and missing-home screen.'
} finally {
  if ($desktop -and -not $desktop.HasExited) {Stop-MusicServerSmokeDesktop -Process $desktop}
  foreach($listener in $foreign){$listener.Stop()}
  foreach($entry in $disabled){if(Test-Path -LiteralPath $entry.Target){Move-Item -LiteralPath $entry.Target -Destination $entry.Source}}
  foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
}
