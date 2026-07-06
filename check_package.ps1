# Check package status
$pkg = Get-AppxPackage *OtpAuth*
if ($pkg) {
    Write-Host "Package: $($pkg.Name)"
    Write-Host "Location: $($pkg.InstallLocation)"
    Write-Host "Status: $($pkg.Status)"
    Write-Host "DevMode: $($pkg.IsDevelopmentMode)"

    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    if (Test-Path $manifestPath) {
        Write-Host "Manifest exists at: $manifestPath"
        # Check ThemeResources content
        $content = Get-Content $manifestPath -Raw
        if ($content -like "*<DarkMode*") {
            Write-Host "DarkMode tag found"
        }
        if ($content -like "*<LightMode*") {
            Write-Host "LightMode tag found"
        }
    } else {
        Write-Host "Manifest NOT FOUND at: $manifestPath"
    }

    $widgetExe = Join-Path $pkg.InstallLocation "Otpeek.Widget.exe"
    if (Test-Path $widgetExe) {
        Write-Host "Widget.exe exists"
    } else {
        Write-Host "Widget.exe NOT FOUND"
    }
} else {
    Write-Host "Package not installed"
}
