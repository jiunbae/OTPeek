# Check for Widget.exe crash in event logs
Write-Host "=== Checking Application Event Log ===" -ForegroundColor Green

$events = Get-WinEvent -LogName Application -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*Widget*" -or $_.Message -like "*OtpAuth*" -or $_.ProviderName -like "*.NET*" }

if ($events) {
    $events | Format-List TimeCreated, ProviderName, Message
} else {
    Write-Host "No recent events found"
}

# Check .NET Runtime errors
Write-Host "`n=== .NET Runtime Errors ===" -ForegroundColor Yellow
$dotnetEvents = Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq ".NET Runtime" }

if ($dotnetEvents) {
    $dotnetEvents | Select-Object -First 5 | ForEach-Object {
        Write-Host "Time: $($_.TimeCreated)" -ForegroundColor Cyan
        Write-Host $_.Message
        Write-Host ""
    }
} else {
    Write-Host "No .NET runtime events"
}
