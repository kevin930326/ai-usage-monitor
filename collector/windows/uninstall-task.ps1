<#
.SYNOPSIS
  移除 Windows 收集器的排程（install-task.ps1 建立的）。資料夾 %LOCALAPPDATA%\AIUsageMonitor 保留不動，
  不需要時自行刪除。
#>
$ErrorActionPreference = 'Stop'
$TaskPath = '\AIUsageMonitor\'
$TaskName = 'Collector'
$task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
    Write-Host "已移除排程：$TaskPath$TaskName"
} else {
    Write-Host '沒有安裝排程。'
}
Write-Host "資料保留在 $(Join-Path $env:LOCALAPPDATA 'AIUsageMonitor')；不需要時可自行刪除。"
