<#
.SYNOPSIS
  Windows 收集器（ADR-0011 第 2 節、FR-48）：以工作排程器每 5 分鐘統計這台電腦的 Token。

.DESCRIPTION
  與 Mac 共用同一份 Python 程式（collector\usage_collector），只用標準函式庫。
  - 資料夾：%LOCALAPPDATA%\AIUsageMonitor（history.sqlite3、config.json、collector.log）
  - 對話紀錄：%USERPROFILE%\.claude、%USERPROFILE%\.codex（CLAUDE_CONFIG_DIR、CODEX_HOME 或 config.json 的
    claude_config_dir、codex_home 優先）
  - 以 pythonw.exe 執行（不開主控台視窗），-X utf8 讓檔案一律以 UTF-8 讀寫；收集器自己降到 BELOW_NORMAL 優先順序
  - 預設只統計 Token、不收集額度、不上傳任何東西
  再執行一次會以新的設定取代舊的排程。移除：uninstall-task.ps1。

.PARAMETER WithQuota
  另外收集額度（執行 claude -p /usage、codex app-server），結果只寫在本機 usage.json，不上傳。
  ADR-0011 的預設是 Windows 不收集額度（額度是整個帳號的數字，Mac 已經在收集）；需要時才加。

.PARAMETER Python
  Python 3.10 以上的 python.exe 完整路徑。預設用 py 啟動器找到的 Python 3，再退回 PATH 中的 python。
#>
param(
    [switch]$WithQuota,
    [string]$Python
)
$ErrorActionPreference = 'Stop'

$TaskPath = '\AIUsageMonitor\'
$TaskName = 'Collector'
$Collector = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $env:LOCALAPPDATA 'AIUsageMonitor'
$Config = Join-Path $DataDir 'config.json'
$Log = Join-Path $DataDir 'collector.log'

if (-not $Python) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) { $Python = (& $launcher.Source -3 -c 'import sys; print(sys.executable)').Trim() }
}
if (-not $Python) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { $Python = $found.Source }
}
if (-not $Python -or -not (Test-Path $Python)) {
    throw '找不到 Python 3。請從 python.org 安裝 Python 3.10 以上（勾選 py launcher），或以 -Python 指定 python.exe。'
}
& $Python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
if ($LASTEXITCODE -ne 0) { throw "$Python 版本太舊，需要 Python 3.10 以上。" }
$Pythonw = Join-Path (Split-Path -Parent $Python) 'pythonw.exe'
if (-not (Test-Path $Pythonw)) { throw "找不到 $Pythonw（Microsoft Store 版的 Python 請改用 python.org 的安裝程式）。" }

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$UpdateConfig = Join-Path $Collector 'scripts\update-config.py'

# 合併寫入 config.json 的一個欄位；失敗時中止安裝（不留下缺少設定的排程）。
# 字串陣列用 --list 逐項傳入：Windows PowerShell 5.1 會吃掉外部程式參數裡的雙引號，JSON 傳不過去
function Update-Config([string[]]$ConfigArgs) {
    & $Python -X utf8 $UpdateConfig @ConfigArgs
    if ($LASTEXITCODE -ne 0) { throw "無法寫入 $Config，沒有安裝排程。" }
}

if ($WithQuota) {
    # 安裝時找到的 CLI 寫進 config.json（排程執行時的 PATH 可能不同）；找不到的服務不啟用
    $enabled = @()
    foreach ($name in @('claude', 'codex')) {
        # 只取能直接啟動的 .exe／.cmd／.bat：npm 另外產生的 .ps1 要經過 PowerShell，收集器無法直接執行
        $cmd = Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue |
            Where-Object { @('.exe', '.cmd', '.bat') -contains [IO.Path]::GetExtension($_.Source).ToLower() } |
            Select-Object -First 1
        if ($cmd) {
            Update-Config @($Config, "$($name)_path", $cmd.Source)
            $enabled += $name
        }
    }
    if ($enabled.Count -eq 0) { Write-Warning '找不到 claude 或 codex，額度不會收集（Token 統計照常）。' }
    Update-Config (@('--list', $Config, 'enabled_providers') + $enabled)
    $Mode = '--write-local'
} else {
    $Mode = '--tokens-only'
}

$Arguments = "-X utf8 -m usage_collector --quiet $Mode --log-file `"$Log`""
$Action = New-ScheduledTaskAction -Execute $Pythonw -Argument $Arguments -WorkingDirectory $Collector
# 每 5 分鐘（不設結束時間＝無限期），另外在登入時執行一次
$Every5 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$AtLogOn = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
# 只在使用者登入時以使用者本人身分執行（不存密碼、不提高權限）
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $Action -Trigger @($Every5, $AtLogOn) `
    -Settings $Settings -Principal $Principal -Description 'AI Usage Monitor：每 5 分鐘統計本機的 Token（ADR-0011）' -Force | Out-Null
Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName

Write-Host "已安裝排程：$TaskPath$TaskName（每 5 分鐘，$Mode）"
Write-Host "資料夾：$DataDir"
Write-Host "日誌：$Log"
Write-Host '第一次會整理過去的對話紀錄，每次最多 64 MB，可能要跑幾輪；進度看 history.sqlite3 的 meta.first_scan_progress。'
