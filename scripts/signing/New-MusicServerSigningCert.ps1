# Creates (idempotently) the self-signed code-signing certificate that signs
# MusicServer installers, exports its public half and installs trust for it.
#
# Why this exists: an unsigned installer triggers the Windows "unknown publisher"
# / SmartScreen confirmation on every download. A purchased code-signing
# certificate is the only fix that works on machines that never saw this repo, but
# a self-signed certificate plus a trusted-publisher entry removes the prompt on
# the machines where it is imported -- which is what this script does.
#
# The private key stays in the current user's certificate store. Only the public
# .cer is written out (and is safe to keep in the repository so another machine can
# import trust without rebuilding anything).
[CmdletBinding()]
param(
    [string]$Subject = 'CN=MusicServer',
    [int]$Years = 5,
    [string]$ExportPath,
    [switch]$SkipTrust,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated while parameter defaults are evaluated, so the
# default export path is resolved here instead.
if (-not $ExportPath) { $ExportPath = Join-Path $PSScriptRoot 'MusicServer-CodeSigning.cer' }

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExistingSigningCert {
    param([string]$CertificateSubject)
    Get-ChildItem 'Cert:\CurrentUser\My' |
        Where-Object { $_.Subject -eq $CertificateSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function Import-Trust {
    param([string]$CertificatePath, [string]$Thumbprint)
    $stores = @()
    if (Test-IsElevated) {
        $stores = @('Cert:\LocalMachine\TrustedPublisher', 'Cert:\LocalMachine\Root')
    }
    else {
        $stores = @('Cert:\CurrentUser\TrustedPublisher')
    }
    foreach ($store in $stores) {
        $existing = Get-ChildItem $store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint }
        if ($existing) {
            Write-Host "trust already present in $store"
            continue
        }
        Import-Certificate -FilePath $CertificatePath -CertStoreLocation $store | Out-Null
        Write-Host "imported trust into $store"
    }
    if (-not (Test-IsElevated)) {
        Write-Warning 'Not elevated: only the per-user TrustedPublisher store was updated. Run this script from an elevated shell so the certificate also lands in the machine Root store, which is what removes the "unknown publisher" line.'
    }
}

if ($Force) {
    Get-ChildItem 'Cert:\CurrentUser\My' |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
        ForEach-Object { Remove-Item ("Cert:\CurrentUser\My\" + $_.Thumbprint) -Force }
}

$cert = Get-ExistingSigningCert -CertificateSubject $Subject
if ($cert) {
    Write-Host "reusing existing signing certificate $($cert.Thumbprint) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
}
else {
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears($Years)
    Write-Host "created signing certificate $($cert.Thumbprint) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
}

Export-Certificate -Cert $cert -FilePath $ExportPath -Type CERT | Out-Null
Write-Host "exported public certificate to $ExportPath"

if (-not $SkipTrust) {
    Import-Trust -CertificatePath $ExportPath -Thumbprint $cert.Thumbprint
}

Write-Host ''
Write-Host "thumbprint : $($cert.Thumbprint)"
Write-Host "subject    : $($cert.Subject)"
Write-Host "expires    : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host ''
Write-Host 'Sign a built installer with:'
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\signing\Sign-MusicServerArtifact.ps1 -Path <installer.exe>"
