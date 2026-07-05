# Widget Diagnostic Script
Write-Host "=== OTP Widget Diagnostic ===" -ForegroundColor Cyan

# 1. Package Check
Write-Host "`n[1] Package Check" -ForegroundColor Green
$pkg = Get-AppxPackage *OtpAuth*
if ($pkg) {
    Write-Host "  Name: $($pkg.Name)"
    Write-Host "  Status: $($pkg.Status)"
    Write-Host "  SignatureKind: $($pkg.SignatureKind)"
    Write-Host "  IsDevelopmentMode: $($pkg.IsDevelopmentMode)"
    Write-Host "  InstallLocation: $($pkg.InstallLocation)"
} else {
    Write-Host "  Package NOT INSTALLED!" -ForegroundColor Red
    exit
}

# 2. Widget.exe Check
Write-Host "`n[2] Widget.exe Check" -ForegroundColor Green
$widgetExe = Join-Path $pkg.InstallLocation "OtpAuthenticator.Widget.exe"
if (Test-Path $widgetExe) {
    $fileInfo = Get-Item $widgetExe
    Write-Host "  Found: $widgetExe"
    Write-Host "  Size: $($fileInfo.Length) bytes"
    Write-Host "  Modified: $($fileInfo.LastWriteTime)"
} else {
    Write-Host "  Widget.exe NOT FOUND!" -ForegroundColor Red
}

# 3. Widget Log Check
Write-Host "`n[3] Widget Log" -ForegroundColor Green
$logPath = Join-Path $env:LOCALAPPDATA "OtpAuthenticator\widget.log"
if (Test-Path $logPath) {
    Write-Host "  Log file exists at: $logPath"
    Write-Host "  Last 10 lines:"
    Get-Content $logPath -Tail 10 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "  No widget log (Widget never started)"
}

# 4. Test Widget.exe manually
Write-Host "`n[4] Testing Widget.exe Startup" -ForegroundColor Green
if (Test-Path $widgetExe) {
    # Clear old log
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    $proc = Start-Process -FilePath $widgetExe -ArgumentList "-RegisterProcessAsComServer" -PassThru
    Start-Sleep -Seconds 3

    if (-not $proc.HasExited) {
        Write-Host "  Widget.exe is RUNNING (PID: $($proc.Id))" -ForegroundColor Green
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "  Widget.exe CRASHED with exit code: $($proc.ExitCode)" -ForegroundColor Red
    }

    # Check log
    if (Test-Path $logPath) {
        Write-Host "  Log after test:"
        Get-Content $logPath | ForEach-Object { Write-Host "    $_" }
    }
}

# 5. Check Windows Widget Service
Write-Host "`n[5] Windows Widget Service" -ForegroundColor Green
$widgetProc = Get-Process -Name "Widgets" -ErrorAction SilentlyContinue
if ($widgetProc) {
    Write-Host "  Widgets process running (PID: $($widgetProc.Id))"
} else {
    Write-Host "  Widgets process NOT running"
}

# 6. Check if other widgets work
Write-Host "`n[6] Other Widget Packages" -ForegroundColor Green
$widgetPkgs = Get-AppxPackage | Where-Object {
    $manifest = Join-Path $_.InstallLocation "AppxManifest.xml"
    if (Test-Path $manifest) {
        (Get-Content $manifest -Raw -ErrorAction SilentlyContinue) -like "*com.microsoft.windows.widgets*"
    }
} | Select-Object -First 5

foreach ($wp in $widgetPkgs) {
    Write-Host "  - $($wp.Name) (DevMode: $($wp.IsDevelopmentMode))"
}

Write-Host "`n=== Diagnostic Complete ===" -ForegroundColor Cyan
