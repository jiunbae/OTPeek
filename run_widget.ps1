# Run Widget.exe and check for errors
$widgetPath = "F:\workspace\OTPWidget\src\OtpAuthenticator.App\bin\x64\Release\net8.0-windows10.0.22621.0\OtpAuthenticator.Widget.exe"
$logPath = Join-Path $env:LOCALAPPDATA "OtpAuthenticator\widget.log"

Write-Host "Starting Widget.exe..."
Write-Host "Path: $widgetPath"

# Delete old log
if (Test-Path $logPath) {
    Remove-Item $logPath -Force
}

try {
    $proc = Start-Process -FilePath $widgetPath -ArgumentList "-RegisterProcessAsComServer" -PassThru
    Write-Host "Process started with PID: $($proc.Id)"

    Start-Sleep -Seconds 3

    # Check if still running
    if (-not $proc.HasExited) {
        Write-Host "Widget is running (PID: $($proc.Id))"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Widget exited with code: $($proc.ExitCode)"
    }
} catch {
    Write-Host "Error: $_"
}

# Check log
Write-Host "`n=== Widget Log ==="
if (Test-Path $logPath) {
    Get-Content $logPath
} else {
    Write-Host "No log file created"
}
