<#
.SYNOPSIS
  第二層（多裝置 Token 合併，ADR-0011 第 2 節、docs\tier2-setup.md）：讓這台 PC 上傳每日 Token 加總。

.DESCRIPTION
  - 中繼網址寫進 %LOCALAPPDATA%\AIUsageMonitor\config.json（relay_url），並開啟 token_sync
  - 這台 PC 的寫入密鑰（scripts/relay-device.sh add 印出的 aumd_…）提示輸入後存進 Windows 認證管理員
    （一般認證 AIUsageMonitor/device-key），不寫進任何檔案
  - PC 只上傳、不下載（不需要讀取密鑰）；先執行 install-task.ps1 建立排程
  -Disable：關閉上傳（認證管理員裡的密鑰保留）。

.PARAMETER RelayUrl
  中繼網址（https://ai-usage-relay.<帳號>.workers.dev）。已設定過時可省略。

.PARAMETER Python
  python.exe 的完整路徑。預設用 py 啟動器找到的 Python 3，再退回 PATH 中的 python。
#>
param(
    [string]$RelayUrl,
    [string]$Python,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'

$Collector = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $env:LOCALAPPDATA 'AIUsageMonitor'
$Config = Join-Path $DataDir 'config.json'
$UpdateConfig = Join-Path $Collector 'scripts\update-config.py'

if (-not $Python) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) { $Python = (& $launcher.Source -3 -c 'import sys; print(sys.executable)').Trim() }
}
if (-not $Python) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { $Python = $found.Source }
}
if (-not $Python -or -not (Test-Path $Python)) { throw '找不到 Python 3，以 -Python 指定 python.exe。' }

function Update-Config([string[]]$ConfigArgs) {
    & $Python -X utf8 $UpdateConfig @ConfigArgs
    if ($LASTEXITCODE -ne 0) { throw "無法寫入 $Config。" }
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
if ($Disable) {
    Update-Config @('--json', $Config, 'token_sync', 'false')
    Write-Host '已關閉第二層：不再上傳（認證管理員的 AIUsageMonitor/device-key 保留）。'
    exit 0
}

if ($RelayUrl) {
    if (-not $RelayUrl.StartsWith('https://')) { throw '中繼網址必須是 https://（密鑰不能以明文傳送）。' }
    Update-Config @($Config, 'relay_url', $RelayUrl.TrimEnd('/'))
}

Push-Location $Collector
try {
    # 用 python.exe（不是 pythonw）：要在這個視窗提示輸入密鑰（不會顯示）
    & $Python -X utf8 -m usage_collector.credentials store device-key
    if ($LASTEXITCODE -ne 0) { throw '沒有存入寫入密鑰。' }
    Update-Config @('--json', $Config, 'token_sync', 'true')
    & $Python -X utf8 -m usage_collector.token_sync reset
    if ($LASTEXITCODE -ne 0) { throw '無法重設上傳狀態。' }
} finally {
    Pop-Location
}
Write-Host '已開啟第二層。排程下一輪（5 分鐘內）上傳；確認：py -X utf8 -m usage_collector.token_sync status（在 collector 資料夾）'
