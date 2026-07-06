# Check registered widget extensions
Write-Host "=== Checking Widget Extensions ===" -ForegroundColor Green

# Get our package
$pkg = Get-AppxPackage -Name "Otpeek"
if ($pkg) {
    Write-Host "Package: $($pkg.PackageFullName)"

    # Read manifest
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    [xml]$manifest = Get-Content $manifestPath

    # Check extensions
    $ns = @{
        default = "http://schemas.microsoft.com/appx/manifest/foundation/windows10"
        uap3 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/3"
        com = "http://schemas.microsoft.com/appx/manifest/com/windows10"
    }

    Write-Host "`n=== COM Server ===" -ForegroundColor Yellow
    $comServer = Select-Xml -Xml $manifest -XPath "//com:ExeServer" -Namespace $ns
    if ($comServer) {
        Write-Host "Executable: $($comServer.Node.Executable)"
        Write-Host "Arguments: $($comServer.Node.Arguments)"
        $class = $comServer.Node.Class
        Write-Host "ClassId: $($class.Id)"
    }

    Write-Host "`n=== Widget Extension ===" -ForegroundColor Yellow
    $widgetExt = Select-Xml -Xml $manifest -XPath "//uap3:AppExtension[@Name='com.microsoft.windows.widgets']" -Namespace $ns
    if ($widgetExt) {
        Write-Host "Found widget extension:"
        Write-Host "  Name: $($widgetExt.Node.Name)"
        Write-Host "  DisplayName: $($widgetExt.Node.DisplayName)"
        Write-Host "  Id: $($widgetExt.Node.Id)"
        Write-Host "  PublicFolder: $($widgetExt.Node.PublicFolder)"
    } else {
        Write-Host "NO WIDGET EXTENSION FOUND!" -ForegroundColor Red
    }
}

# List all packages with widget extensions
Write-Host "`n=== All Packages with Widget Extensions ===" -ForegroundColor Green
$allPkgs = Get-AppxPackage | Where-Object {
    $manifest = Join-Path $_.InstallLocation "AppxManifest.xml"
    if (Test-Path $manifest) {
        $content = Get-Content $manifest -Raw
        $content -like "*com.microsoft.windows.widgets*"
    }
}

foreach ($p in $allPkgs) {
    Write-Host "  - $($p.Name)"
}
