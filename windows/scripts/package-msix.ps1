#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a distributable MSIX package for the OTPeek Windows app.

.DESCRIPTION
    Three output modes:
      * -Mode Store    → produces a .msixupload for Microsoft Partner Center
                         (unsigned; the Store re-signs with your publisher identity).
      * -Mode Sideload → produces a signed .msix you can install directly, signed
                         with either a PFX at -CertPath or a certificate already in
                         the CurrentUser certificate store at -CertThumbprint.
      * -Mode Dev      → builds an unsigned loose package and registers it for the
                         current developer account. This is the quickest way to test
                         Start-menu branding, protocols, and the Windows widget provider.

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

.EXAMPLE
    # Sign without exporting the private key from the certificate store
    ./windows/scripts/package-msix.ps1 -Mode Sideload -Platforms x64 `
        -CertThumbprint 0123456789ABCDEF0123456789ABCDEF01234567

.EXAMPLE
    # Register an unsigned development package for this Windows account
    ./windows/scripts/package-msix.ps1 -Mode Dev -Platforms x64

.NOTES
    Before a Store submission, reserve the app name in Partner Center and paste the
    Identity/Name + Publisher values it gives you into windows/Otpeek.App/Package.appxmanifest
    (see docs/RELEASE.md). The committed manifest uses placeholder identity values.
#>
[CmdletBinding()]
param(
    [ValidateSet('Store', 'Sideload', 'Dev')]
    [string]$Mode = 'Store',

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Platforms = @('x64'),

    [string]$Configuration = 'Release',

    # Sideload signing (exactly one is required for -Mode Sideload).
    [string]$CertPath,
    [string]$CertThumbprint,
    [System.Security.SecureString]$CertPassword
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..\..')
$AppProj   = Join-Path $RepoRoot 'windows\Otpeek.App\Otpeek.App.csproj'
$OutDir    = Join-Path $RepoRoot 'windows\Otpeek.App\AppPackages'

# OpenSSH and scheduled shells do not always receive rustup's interactive PATH.
# Prefer the installed stable MSVC toolchain directly when it is available, avoiding
# a broken/missing cargo proxy while preserving normal developer-shell behavior.
$rustupToolchains = Join-Path $env:USERPROFILE '.rustup\toolchains'
$stableToolchainBin = Get-ChildItem -Path $rustupToolchains -Directory -Filter 'stable-*-windows-msvc' -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'bin' } |
    Where-Object { Test-Path (Join-Path $_ 'cargo.exe') } |
    Select-Object -First 1
if ($stableToolchainBin) {
    $env:Path = "$stableToolchainBin;$env:Path"
}
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) {
    throw 'Rust cargo was not found. Install the stable MSVC toolchain with rustup before packaging.'
}

$platformList = $Platforms -join '|'

if ($Mode -eq 'Dev' -and $Platforms.Count -ne 1) {
    throw 'Dev mode supports exactly one platform at a time.'
}

Write-Host "==> OTPeek MSIX package  (mode=$Mode  platforms=$platformList  config=$Configuration)" -ForegroundColor Cyan

$buildMode = if ($Mode -eq 'Store') { 'StoreUpload' } else { 'SideloadOnly' }
$bundleMode = if ($Mode -eq 'Dev') { 'Never' } else { 'Always' }

$common = @(
    "-c", $Configuration,
    "-p:WindowsPackageType=MSIX",
    "-p:GenerateAppxPackageOnBuild=true",
    "-p:AppxBundlePlatforms=$platformList",
    "-p:AppxBundle=$bundleMode",
    "-p:UapAppxPackageBuildMode=$buildMode",
    "-p:AppxPackageDir=$OutDir\"
)

# A single-platform package must build the project for that concrete architecture.
# AppxBundlePlatforms controls packaging only; it does not set MSBuild's Platform and
# otherwise leaves the self-contained Windows App SDK build at unsupported AnyCPU.
if ($Platforms.Count -eq 1) {
    $common += "-p:Platform=$($Platforms[0])"
}

if ($Mode -in @('Store', 'Dev')) {
    # Store re-signs — do not sign locally.
    $common += "-p:AppxPackageSigningEnabled=false"
}
else {
    if ([bool]$CertPath -eq [bool]$CertThumbprint) {
        throw 'Sideload mode requires exactly one of -CertPath or -CertThumbprint.'
    }

    $common += "-p:AppxPackageSigningEnabled=true"
    if ($CertThumbprint) {
        $thumbprint = $CertThumbprint.Replace(' ', '').ToUpperInvariant()
        $certificate = Get-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
        if (-not $certificate -or -not $certificate.HasPrivateKey) {
            throw "A signing certificate with a private key was not found at Cert:\CurrentUser\My\$thumbprint"
        }
        $common += "-p:PackageCertificateThumbprint=$thumbprint"
    }
    else {
        $common += "-p:PackageCertificateKeyFile=$((Resolve-Path $CertPath).Path)"
        if ($CertPassword) {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword))
            $common += "-p:PackageCertificatePassword=$plain"
        }
    }
}

Write-Host "==> dotnet build $AppProj $($common -join ' ')" -ForegroundColor DarkGray
dotnet build $AppProj @common
if ($LASTEXITCODE -ne 0) {
    throw "MSIX build failed with exit code $LASTEXITCODE."
}

if ($Mode -eq 'Dev') {
    $binRoot = Join-Path $RepoRoot "windows\Otpeek.App\bin\$($Platforms[0])\$Configuration"
    $layoutManifest = Get-ChildItem -Path $binRoot -Filter AppxManifest.xml -Recurse -File |
        Where-Object { Test-Path (Join-Path $_.Directory.FullName 'Otpeek.exe') } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $layoutManifest) {
        throw "The build completed but no loose package AppxManifest.xml was found below $binRoot."
    }

    # Register from a stable per-user staging directory. AppX adjusts ACLs on a loose
    # package's install location; pointing it at bin\ would make later rebuilds and
    # cleanup unnecessarily fragile.
    $devLayout = Join-Path $env:LOCALAPPDATA 'Otpeek.DevPackage'
    Write-Host "==> Staging development package: $devLayout" -ForegroundColor Cyan
    Get-Process Otpeek -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process 'Otpeek.Widget' -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-AppxPackage -Name Otpeek -ErrorAction SilentlyContinue |
        Remove-AppxPackage -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $devLayout) {
        Remove-Item -LiteralPath $devLayout -Recurse -Force
    }
    New-Item -ItemType Directory -Path $devLayout | Out-Null
    Copy-Item -Path (Join-Path $layoutManifest.Directory.FullName '*') `
        -Destination $devLayout -Recurse -Force

    $devManifest = Join-Path $devLayout 'AppxManifest.xml'
    Write-Host "==> Registering development package: $devManifest" -ForegroundColor Cyan

    try {
        Add-AppxPackage -Register $devManifest -ForceApplicationShutdown
    }
    catch {
        Write-Host "Development registration failed. The AppX deployment event log contains the authoritative reason." -ForegroundColor Red
        Write-Host "If HRESULT 0x80070005 names a stale folder under WindowsApps\Deleted, restart Windows or remove only that orphaned package from an elevated shell, then rerun this command." -ForegroundColor Yellow
        if ($env:SSH_CONNECTION) {
            Write-Host "AppX PLM registration can also reject an OpenSSH service session. Run this Dev command once from PowerShell in the logged-in Windows desktop." -ForegroundColor Yellow
        }
        throw
    }

    $package = Get-AppxPackage -Name Otpeek -ErrorAction Stop
    Write-Host "==> Registered: $($package.PackageFullName)" -ForegroundColor Green
    Write-Host "    Open the Windows widget picker and add OTPeek." -ForegroundColor Green
}

Write-Host ""
Write-Host "==> Done. Artifacts in: $OutDir" -ForegroundColor Green
Get-ChildItem -Path $OutDir -Recurse -Include *.msix, *.msixbundle, *.msixupload -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Green }
