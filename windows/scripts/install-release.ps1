#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the signed OTPeek GitHub release for the current Windows user.

.DESCRIPTION
    Verifies that the MSIX bundle is signed by the certificate shipped beside this
    script, trusts only that public certificate in the local-machine TrustedPeople
    store, and installs the package. Windows requests elevation only when the
    certificate has not already been trusted.
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$CertificatePath
)

$ErrorActionPreference = 'Stop'
$releaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $PackagePath) {
    $PackagePath = Get-ChildItem -Path $releaseDir -File |
        Where-Object { $_.Extension -in @('.msix', '.msixbundle') } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $CertificatePath) {
    $CertificatePath = Get-ChildItem -Path $releaseDir -Filter '*.cer' -File |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $PackagePath -or -not (Test-Path $PackagePath)) {
    throw 'The OTPeek .msix or .msixbundle file was not found beside this script.'
}
if (-not $CertificatePath -or -not (Test-Path $CertificatePath)) {
    throw 'The OTPeek public signing certificate (.cer) was not found beside this script.'
}

$package = (Resolve-Path $PackagePath).Path
$certificateFile = (Resolve-Path $CertificatePath).Path
$releaseCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateFile)
$signature = Get-AuthenticodeSignature -FilePath $package

if (-not $signature.SignerCertificate) {
    throw 'The OTPeek package is not signed.'
}
if ($signature.SignerCertificate.Thumbprint -ne $releaseCertificate.Thumbprint) {
    throw 'The package signature does not match the bundled OTPeek certificate.'
}
if ($signature.Status -in @('HashMismatch', 'NotSigned')) {
    throw "The OTPeek package signature is invalid: $($signature.StatusMessage)"
}

$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople |
    Where-Object Thumbprint -eq $releaseCertificate.Thumbprint |
    Select-Object -First 1
if (-not $trusted) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdministrator) {
        Write-Host 'Windows will request approval to trust the OTPeek release certificate...'
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-PackagePath', ('"{0}"' -f $package),
            '-CertificatePath', ('"{0}"' -f $certificateFile)
        )
        $elevated = Start-Process -FilePath powershell.exe -Verb RunAs `
            -ArgumentList $arguments -Wait -PassThru
        if ($elevated.ExitCode -ne 0) {
            throw "The elevated OTPeek installer exited with code $($elevated.ExitCode)."
        }
        return
    }

    Write-Host 'Trusting the OTPeek release certificate for this Windows installation...'
    Import-Certificate -FilePath $certificateFile `
        -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
}

Write-Host 'Installing OTPeek...'
$developmentPackage = Get-AppxPackage -Name Otpeek -ErrorAction SilentlyContinue |
    Where-Object SignatureKind -eq 'None' |
    Select-Object -First 1
if ($developmentPackage) {
    Write-Host 'Replacing the existing OTPeek development registration...'
    Remove-AppxPackage -Package $developmentPackage.PackageFullName
}
Add-AppxPackage -Path $package -ForceApplicationShutdown
Write-Host 'OTPeek is installed. Open it from the Start menu.' -ForegroundColor Green
