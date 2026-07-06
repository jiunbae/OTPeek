# Diagnose Otpeek App Issues

Write-Host "=== Package Info ===" -ForegroundColor Cyan
Get-AppxPackage -Name '*OtpAuth*' | Format-List Name, Version, Status, InstallLocation

Write-Host "`n=== Check Package Files ===" -ForegroundColor Cyan
$pkg = Get-AppxPackage -Name '*OtpAuth*'
if ($pkg) {
    $installPath = $pkg.InstallLocation
    Write-Host "Install Location: $installPath"

    if (Test-Path $installPath) {
        Write-Host "`nFiles in package:"
        Get-ChildItem $installPath -Recurse | Select-Object FullName | Format-Table -AutoSize
    } else {
        Write-Host "ERROR: Install location does not exist!" -ForegroundColor Red
    }
}

Write-Host "`n=== Recent App Errors ===" -ForegroundColor Cyan
Get-WinEvent -LogName 'Application' -MaxEvents 50 |
    Where-Object { $_.Message -match 'OtpAuth|Otpeek' } |
    Select-Object TimeCreated, LevelDisplayName, Message |
    Format-List

Write-Host "`n=== Try Launch App ===" -ForegroundColor Cyan
try {
    Start-Process "shell:AppsFolder\Otpeek_akbja7an2c1qp!App" -ErrorAction Stop
    Write-Host "App launch command sent"
} catch {
    Write-Host "Launch Error: $_" -ForegroundColor Red
}

Write-Host "`nWait 3 seconds and check for process..."
Start-Sleep -Seconds 3
$proc = Get-Process -Name 'Otpeek' -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "App is running! PID: $($proc.Id)" -ForegroundColor Green
} else {
    Write-Host "App is NOT running - crashed on startup?" -ForegroundColor Red
}
