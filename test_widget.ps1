$widgetPath = "F:\workspace\OTPeek\src\Otpeek.App\bin\x64\Release\net8.0-windows10.0.22621.0\Otpeek.Widget.exe"

Write-Host "Testing Widget.exe startup..."
Write-Host "Path: $widgetPath"

try {
    $process = Start-Process -FilePath $widgetPath -ArgumentList "-RegisterProcessAsComServer" -PassThru -Wait -NoNewWindow
    Write-Host "Exit code: $($process.ExitCode)"
} catch {
    Write-Host "Error: $_"
}
