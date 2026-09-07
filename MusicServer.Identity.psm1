# Runtime identity is derived from shipped source bytes, never machine paths.
function Get-MusicServerBuildIdentity {
    param([Parameter(Mandatory)][string]$Root)
    $names = @('start_musicserver_ui.ps1','watchdog_ui.ps1','music_api.ps1','wanted_worker.ps1','MusicServer.Core.psm1','MusicServer.Database.psm1','MusicServer.Http.psm1','MusicServer.State.psm1','MusicServer.Providers.psm1','MusicServer.Identity.psm1')
    $web = Join-Path $Root 'web'
    if (Test-Path -LiteralPath $web -PathType Container) {
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        $names += @(Get-ChildItem -LiteralPath $web -File -Recurse | ForEach-Object { $_.FullName.Substring($prefix.Length).Replace('\','/') })
    }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $records = foreach ($name in $names) {
        $path = Join-Path $Root $name
        $hash = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'missing' }
        $name + ':' + $hash
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
        return 'musicserver-' + ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
Export-ModuleMember -Function Get-MusicServerBuildIdentity
