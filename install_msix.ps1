# Install MSIX Package Script
param(
    [switch]$Reinstall
)

$ErrorActionPreference = 'Stop'

# 1. Export certificate from Current User store
$cert = Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -eq 'CN=OtpAuthenticator' } | Select-Object -First 1
if ($cert) {
    Write-Host "Found certificate: $($cert.Thumbprint)"
    Export-Certificate -Cert $cert -FilePath "$PSScriptRoot\OtpAuthenticator.cer" -Type CERT
    Write-Host "Certificate exported to OtpAuthenticator.cer"
} else {
    Write-Host "Certificate not found!"
    exit 1
}

# 2. Import certificate to Trusted Root (requires admin)
Write-Host "Importing certificate to Trusted Root..."
Import-Certificate -FilePath "$PSScriptRoot\OtpAuthenticator.cer" -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null

function Get-SignToolPath {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kitRoot) {
        $tool = Get-ChildItem -LiteralPath $kitRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($tool) {
            return $tool.FullName
        }
    }

    throw "signtool.exe was not found. Install Windows SDK Build Tools or sign the MSIX manually."
}

function Ensure-PackageSigned {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$Package,

        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Package.FullName
    if ($signature.Status -eq 'Valid') {
        return $true
    }

    Write-Host "Signing app package: $($Package.FullName)"
    $signTool = Get-SignToolPath
    & $signTool sign /fd SHA256 /sha1 $Certificate.Thumbprint $Package.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Signing failed for: $($Package.FullName)"
        return $false
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Package.FullName
    return $signature.Status -eq 'Valid'
}

# 3. Install the app package. Files under MsixContent\MSIX are WinAppRuntime dependencies.
$packageRoot = Join-Path $PSScriptRoot 'windows\OtpAuthenticator.App'
$packageExtensions = @('.msixbundle', '.msix', '.appxbundle', '.appx')
$packages = Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
    Where-Object { $_.Extension -in $packageExtensions } |
    Where-Object { $_.Name -like 'OtpAuthenticator.App_*' } |
    Where-Object { $_.FullName -notmatch '\\MsixContent\\MSIX\\' } |
    Sort-Object @{ Expression = 'LastWriteTime'; Descending = $true }, @{ Expression = { if ($_.Extension -in @('.msix', '.appx')) { 0 } else { 1 } }; Ascending = $true }

if (-not $packages) {
    throw "App MSIX package was not found under: $packageRoot"
}

$msix = $null
foreach ($package in $packages) {
    if (Ensure-PackageSigned -Package $package -Certificate $cert) {
        $msix = $package
        break
    }
}

if (-not $msix) {
    throw "No signed app package was available under: $packageRoot"
}

$msixPath = $msix.FullName
Write-Host "Installing app package from: $msixPath"

$appDataBackupPath = $null
$appDataRestorePath = $null

if ($Reinstall) {
    $existingPackage = Get-AppxPackage -Name 'OtpAuthenticator' -ErrorAction SilentlyContinue
    if ($existingPackage) {
        $appDataPath = Join-Path $env:LOCALAPPDATA "Packages\$($existingPackage.PackageFamilyName)"
        if (Test-Path -LiteralPath $appDataPath) {
            $backupRoot = Join-Path $PSScriptRoot 'AppDataBackups'
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = Join-Path $backupRoot "$($existingPackage.PackageFamilyName)-$timestamp"
            Write-Host "Backing up app data to: $backupPath"
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            Get-ChildItem -LiteralPath $appDataPath -Force | Copy-Item -Destination $backupPath -Recurse -Force
            $appDataBackupPath = $backupPath
            $appDataRestorePath = $appDataPath
        }

        Write-Host "Removing existing package: $($existingPackage.PackageFullName)"
        Remove-AppxPackage -Package $existingPackage.PackageFullName
    }
}

try {
    Add-AppxPackage -Path $msixPath -ForceApplicationShutdown -ForceUpdateFromAnyVersion
} catch {
    Write-Warning $_.Exception.Message

    $activityId = $null
    if ($_.Exception.Message -match '\[ActivityId\]\s+([0-9a-fA-F-]+)') {
        $activityId = $matches[1]
    }

    if ($activityId) {
        Write-Host "Deployment log for ActivityId ${activityId}:"
        $log = Get-AppPackageLog -ActivityID $activityId
        $log | Select-Object Time, Id, Message | Format-List

        if ($log.Message -match 'WindowsApps\\Deleted\\Microsoft\.GamingServices') {
            Write-Warning "Windows AppX deployment is blocked by stale Microsoft.GamingServices files under C:\Program Files\WindowsApps\Deleted. Restart Windows, then run this script before opening Xbox or Gaming Services. If it still fails, repair/reset or reinstall Microsoft Gaming Services, then retry."
        }
    }

    throw $_
}

if ($appDataBackupPath -and $appDataRestorePath -and (Test-Path -LiteralPath $appDataBackupPath)) {
    Write-Host "Restoring app data from: $appDataBackupPath"
    New-Item -ItemType Directory -Path $appDataRestorePath -Force | Out-Null
    Get-ChildItem -LiteralPath $appDataBackupPath -Force | Copy-Item -Destination $appDataRestorePath -Recurse -Force
}

Write-Host "Installation complete!"
