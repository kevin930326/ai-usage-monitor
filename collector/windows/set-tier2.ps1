<#
.SYNOPSIS
  第二層（多裝置 Token 合併，ADR-0011 第 2 節、ADR-0015 第 3 節、docs\tier2-setup.md）：讓這台 PC 上傳每日 Token 加總，
  加 -ReadKey 時也下載其他電腦的（給 Windows App 顯示「所有電腦」）。

.DESCRIPTION
  - 中繼網址寫進 %LOCALAPPDATA%\AIUsageMonitor\config.json（relay_url），並開啟 token_sync
  - 這台 PC 的寫入密鑰（scripts/relay-device.sh add 印出的 aumd_…）提示輸入後存進 Windows 認證管理員
    （一般認證 AIUsageMonitor/device-key），不寫進任何檔案；已存過時可加 -KeepDeviceKey 沿用
  - 貼上的密鑰先檢查格式（去掉前後空白與換行；寫入密鑰要 aumd_ 開頭、48 字元），不對就當場重新提示（最多 3 次）
  - 讀取密鑰（下載其他電腦的每日加總）：-ReadKey 存入（AIUsageMonitor/relay-read），收集器每小時下載並寫進本機
    history.sqlite3；-NoReadKey 刪除讀取密鑰與下載的資料（回到只上傳）；兩者都不加時不動之前的設定
  - 額度快照（/usage）仍只由 Mac 上傳，PC 不上傳（ADR-0015 第 3 節）；先執行 install-task.ps1 建立排程
  -Disable：關閉上傳與下載（認證管理員裡的密鑰保留；刪除本機的其他電腦資料）。

.PARAMETER ReadKey
  也存中繼的讀取密鑰（READ_TOKEN，和 iPhone App 用的相同），下載其他電腦的每日加總。

.PARAMETER NoReadKey
  刪除之前存的讀取密鑰與下載的其他電腦資料，只上傳。

.PARAMETER KeepDeviceKey
  沿用認證管理員裡已存的寫入密鑰，不重新提示（例如只想加上 -ReadKey）。沒有存過時停止。

.PARAMETER RelayUrl
  中繼網址（https://ai-usage-relay.<帳號>.workers.dev）。已設定過時可省略。

.PARAMETER Python
  python.exe 的完整路徑。預設用 py 啟動器找到的 Python 3，再退回 PATH 中的 python。
#>
param(
    [string]$RelayUrl,
    [string]$Python,
    [switch]$ReadKey,
    [switch]$NoReadKey,
    [switch]$KeepDeviceKey,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'
if ($ReadKey -and $NoReadKey) { throw '-ReadKey 與 -NoReadKey 只能選一個。' }

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
# 在 collector 資料夾執行 python -m usage_collector.<模組> <參數>
function Invoke-Collector([string[]]$ModuleArgs, [string]$Failure) {
    Push-Location $Collector
    try {
        & $Python -X utf8 -m @ModuleArgs
        if ($LASTEXITCODE -ne 0) { throw $Failure }
    } finally {
        Pop-Location
    }
}

if ($Disable) {
    Update-Config @('--json', $Config, 'token_sync', 'false')
    # 面板回到「這台電腦」：刪除本機的其他電腦資料（中繼上的資料不動）
    Invoke-Collector @('usage_collector.token_sync', 'forget') '無法刪除本機的其他電腦資料。'
    Write-Host '已關閉第二層：不再上傳與下載（認證管理員的密鑰保留；要移除：cmdkey /delete:AIUsageMonitor/device-key）。'
    exit 0
}

if ($RelayUrl) {
    if (-not $RelayUrl.StartsWith('https://')) { throw '中繼網址必須是 https://（密鑰不能以明文傳送）。' }
    Update-Config @($Config, 'relay_url', $RelayUrl.TrimEnd('/'))
}

# 用 python.exe（不是 pythonw）：要在這個視窗提示輸入密鑰（不會顯示）；格式不對時重新提示，最多 3 次
if ($KeepDeviceKey) {
    Push-Location $Collector
    try { & $Python -X utf8 -m usage_collector.credentials has device-key } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw '認證管理員裡沒有寫入密鑰（AIUsageMonitor/device-key），拿掉 -KeepDeviceKey 重新執行。' }
    Write-Host '沿用已存的寫入密鑰。'
} else {
    Write-Host '請貼上這台 PC 的寫入密鑰（scripts/relay-device.sh add 印出的 aumd_…）：'
    Invoke-Collector @('usage_collector.credentials', 'store', 'device-key') '沒有存入寫入密鑰。'
}
if ($ReadKey) {
    Write-Host '請貼上中繼的讀取密鑰（READ_TOKEN，和 iPhone App 用的相同）：'
    Invoke-Collector @('usage_collector.credentials', 'store', 'relay-read') '沒有存入讀取密鑰。'
} elseif ($NoReadKey) {
    # 只上傳：之前存過的讀取密鑰也要移除，收集器才不會繼續下載（沒有這個項目時忽略）
    Invoke-Collector @('usage_collector.credentials', 'delete', 'relay-read') '無法移除讀取密鑰。'
}
Update-Config @('--json', $Config, 'token_sync', 'true')
# 清除「密鑰失效」等狀態，下一輪立即上傳
Invoke-Collector @('usage_collector.token_sync', 'reset') '無法重設上傳狀態。'
if ($NoReadKey) {
    Invoke-Collector @('usage_collector.token_sync', 'forget') '無法刪除本機的其他電腦資料。'
}
Push-Location $Collector
try { & $Python -X utf8 -m usage_collector.credentials has relay-read } finally { Pop-Location }
$downloads = $LASTEXITCODE -eq 0
$what = if ($downloads) { '上傳這台 PC 的每日加總、每小時下載其他電腦的' } else { '上傳這台 PC 的每日加總（不下載；要下載加 -ReadKey）' }
Write-Host "已開啟第二層：$what。排程下一輪（5 分鐘內）執行；確認：py -X utf8 -m usage_collector.token_sync status（在 collector 資料夾）"
