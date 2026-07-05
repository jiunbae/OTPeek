# Check Widget registration
Write-Host "=== OtpAuthenticator Package Info ===" -ForegroundColor Green

$pkg = Get-AppxPackage -Name "OtpAuthenticator"
if ($pkg) {
    Write-Host "Package found: $($pkg.PackageFullName)"
    Write-Host "Install Location: $($pkg.InstallLocation)"

    # Check manifest
    $manifest = Get-AppxPackageManifest -Package $pkg

    # List extensions
    Write-Host "`n=== Extensions ===" -ForegroundColor Yellow
    $manifest.Package.Applications.Application.Extensions.Extension | ForEach-Object {
        Write-Host "  Category: $($_.Category)"
    }

    # Check COM server
    Write-Host "`n=== COM Server ===" -ForegroundColor Yellow
    $comExt = $manifest.Package.Applications.Application.Extensions.Extension | Where-Object { $_.Category -eq "windows.comServer" }
    if ($comExt) {
        Write-Host "  Executable: $($comExt.ComServer.ExeServer.Executable)"
        Write-Host "  Arguments: $($comExt.ComServer.ExeServer.Arguments)"
        Write-Host "  ClassId: $($comExt.ComServer.ExeServer.Class.Id)"
    }

    # Check Widget extension
    Write-Host "`n=== Widget Extension ===" -ForegroundColor Yellow
    $widgetExt = $manifest.Package.Applications.Application.Extensions.Extension | Where-Object { $_.Category -eq "windows.appExtension" }
    if ($widgetExt) {
        Write-Host "  Name: $($widgetExt.AppExtension.Name)"
        Write-Host "  DisplayName: $($widgetExt.AppExtension.DisplayName)"
        Write-Host "  Id: $($widgetExt.AppExtension.Id)"
    }

    # Check if Widget.exe exists
    Write-Host "`n=== Widget.exe Check ===" -ForegroundColor Yellow
    $widgetExe = Join-Path $pkg.InstallLocation "OtpAuthenticator.Widget.exe"
    if (Test-Path $widgetExe) {
        Write-Host "  Widget.exe exists at: $widgetExe"
    } else {
        Write-Host "  WARNING: Widget.exe NOT FOUND!" -ForegroundColor Red
    }

} else {
    Write-Host "Package not found!" -ForegroundColor Red
}

# Check Widget log
Write-Host "`n=== Widget Log ===" -ForegroundColor Yellow
$logPath = Join-Path $env:LOCALAPPDATA "OtpAuthenticator\widget.log"
if (Test-Path $logPath) {
    Get-Content $logPath
} else {
    Write-Host "  No log file yet"
}
