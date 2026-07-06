#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a distributable MSIX package for the OTPeek Windows app.

.DESCRIPTION
    Two output modes:
      * -Mode Store    → produces a .msixupload for Microsoft Partner Center
                         (unsigned; the Store re-signs with your publisher identity).
      * -Mode Sideload → produces a signed .msix you can install directly, signed
                         with the certificate at -CertPath (PFX).

    The Rust core (otpeek_ffi.dll) is built automatically by the Interop project's
    MSBuild targets, so Rust + the matching MSVC target must be installed.

    Prerequrisites: Visual Studio 2022 (.NET Desktop + Windows App SDK), .NET 8 SDK,
    Rust with the target(s) for the platforms you build.

.EXAMPLE
    # Store upload bundle (x64 + arm64) for Partner Center
    ./windows/scripts/package-msix.ps1 -Mode Store -Platforms x64,arm64

.EXAMPLE
    # Locally-installable signed package
    ./windows/scripts/package-msix.ps1 -Mode Sideload -Platforms x64 `
        -CertPath .\otpeek-dev.pfx -CertPassword (Read-Host -AsSecureString)

.NOTES
    Before a Store submission, reserve the app name in Partner Center and paste the
    Identity/Name + Publisher values it gives you into windows/Otpeek.App/Package.appxmanifest
    (see docs/RELEASE.md). The committed manifest uses placeholder identity values.
#>
[CmdletBinding()]
param(
    [ValidateSet('Store', 'Sideload')]
    [string]$Mode = 'Store',

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Platforms = @('x64'),

    [string]$Configuration = 'Release',

    # Sideload signing (required for -Mode Sideload).
    [string]$CertPath,
    [System.Security.SecureString]$CertPassword
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..\..')
$AppProj   = Join-Path $RepoRoot 'windows\Otpeek.App\Otpeek.App.csproj'
$OutDir    = Join-Path $RepoRoot 'windows\Otpeek.App\AppPackages'

$platformList = $Platforms -join '|'

Write-Host "==> OTPeek MSIX package  (mode=$Mode  platforms=$platformList  config=$Configuration)" -ForegroundColor Cyan

$buildMode = if ($Mode -eq 'Store') { 'StoreUpload' } else { 'SideloadOnly' }

$common = @(
    "-c", $Configuration,
    "-p:AppxBundlePlatforms=$platformList",
    "-p:AppxBundle=Always",
    "-p:UapAppxPackageBuildMode=$buildMode",
    "-p:AppxPackageDir=$OutDir\"
)

if ($Mode -eq 'Store') {
    # Store re-signs — do not sign locally.
    $common += "-p:AppxPackageSigningEnabled=false"
}
else {
    if (-not $CertPath) { throw "Sideload mode requires -CertPath <path-to.pfx>" }
    $common += @(
        "-p:AppxPackageSigningEnabled=true",
        "-p:PackageCertificateKeyFile=$((Resolve-Path $CertPath).Path)"
    )
    if ($CertPassword) {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword))
        $common += "-p:PackageCertificatePassword=$plain"
    }
}

Write-Host "==> dotnet build $AppProj $($common -join ' ')" -ForegroundColor DarkGray
dotnet build $AppProj @common

Write-Host ""
Write-Host "==> Done. Artifacts in: $OutDir" -ForegroundColor Green
Get-ChildItem -Path $OutDir -Recurse -Include *.msix, *.msixbundle, *.msixupload -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Green }
