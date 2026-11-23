<#
.SYNOPSIS
    Removes the ForeverMarketWatchHourlySync Windows Scheduled Task.
#>

$TaskName = "ForeverMarketWatchHourlySync"
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName" -ForegroundColor Yellow
} else {
    Write-Host "Scheduled task '$TaskName' was not registered." -ForegroundColor Gray
}
