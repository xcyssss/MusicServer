# Signs a built MusicServer artifact (the NSIS installer, the desktop exe, the
# packaged launcher) with the certificate created by
# scripts/signing/New-MusicServerSigningCert.ps1.
#
# A machine without the certificate is not an error: the script warns and exits 0,
# so a build or a CI job never fails just because signing is unavailable. Pass
# -RequireSignature when a release must be signed.
#
# signtool is preferred (it timestamps properly and understands the certificate
# store). When the Windows SDK is not installed, Set-AuthenticodeSignature is the
# fallback, which signs but cannot timestamp.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$Subject = 'CN=MusicServer',
    [string]$Thumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$RequireSignature
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SigningCert {
    param([string]$CertificateThumbprint, [string]$CertificateSubject)
    if ($CertificateThumbprint) {
        $cert = Get-ChildItem 'Cert:\CurrentUser\My' |
            Where-Object { $_.Thumbprint -eq $CertificateThumbprint } |
            Select-Object -First 1
        if (-not $cert) { throw "no certificate with thumbprint $CertificateThumbprint in Cert:\CurrentUser\My" }
        return $cert
    }
    return Get-ChildItem 'Cert:\CurrentUser\My' |
        Where-Object { $_.Subject -eq $CertificateSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function Get-SignTool {
    $onPath = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
    if (-not (Test-Path $kits)) { return '' }
    # @() matters: a single match would otherwise be a string, and $string[0] is
    # its first character rather than the path.
    $candidates = @(Get-ChildItem $kits -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return ''
}

$cert = Get-SigningCert -CertificateThumbprint $Thumbprint -CertificateSubject $Subject
if (-not $cert) {
    $message = "no code-signing certificate found for '$Subject' (create one with scripts/signing/New-MusicServerSigningCert.ps1)"
    if ($RequireSignature) { throw $message }
    Write-Warning "$message -- artifacts stay unsigned"
    exit 0
}
Write-Host "signing with $($cert.Subject) [$($cert.Thumbprint)]"

$signTool = Get-SignTool
$results = @()
foreach ($item in $Path) {
    $file = (Resolve-Path -LiteralPath $item).ProviderPath
    if ($signTool) {
        # Build the whole argument list as one array: mixing an array splat with
        # bare tokens makes the parser treat the next token as a command name.
        $signArgs = @('sign', '/sha1', $cert.Thumbprint, '/fd', 'SHA256')
        $output = @()
        $code = 0
        if ($TimestampUrl) {
            $output = & $signTool @($signArgs + @('/td', 'SHA256', '/tr', $TimestampUrl, $file)) 2>&1
            $code = $LASTEXITCODE
        }
        if (-not $TimestampUrl -or $code -ne 0) {
            # A timestamp server being unreachable must not leave the artifact
            # unsigned; sign without a timestamp instead.
            if ($TimestampUrl -and $code -ne 0) { Write-Warning "timestamping failed for $([IO.Path]::GetFileName($file)); signing without a timestamp" }
            $output = & $signTool @($signArgs + $file) 2>&1
            $code = $LASTEXITCODE
        }
        if ($code -ne 0) {
            Write-Host (($output | Out-String).Trim())
            throw "signtool failed for $file (exit $code)"
        }
    }
    else {
        Write-Warning 'signtool.exe not found (Windows SDK missing); falling back to Set-AuthenticodeSignature, which cannot timestamp'
        $null = Set-AuthenticodeSignature -FilePath $file -Certificate $cert -HashAlgorithm SHA256
    }
    $signature = Get-AuthenticodeSignature $file
    $results += [pscustomobject]@{
        File   = [IO.Path]::GetFileName($file)
        Status = $signature.Status
        Signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$invalid = @($results | Where-Object { $_.Status -ne 'Valid' })
if ($invalid.Count -gt 0) {
    # A self-signed certificate only reports Valid once it is trusted on this
    # machine, so this is a trust problem, not a signing problem.
    $message = "signature status is not Valid for: " + (($invalid | ForEach-Object { $_.File }) -join ', ')
    if ($RequireSignature) { throw $message }
    Write-Warning "$message -- import trust with scripts/signing/New-MusicServerSigningCert.ps1"
}
else {
    Write-Host "all $($results.Count) artifact(s) signed and valid"
}
