<#
.SYNOPSIS
  從 repo 建置並安裝 Windows 桌面 App（ADR-0015 第 8 節）。再執行一次＝更新；-Uninstall 移除。

.DESCRIPTION
  1. 找 .NET 10 SDK（dotnet --list-sdks）；沒有時詢問一次，用 winget 安裝 Microsoft.DotNet.SDK.10（目前使用者確認 winget 的協議）。
  2. 依這台電腦的架構（x64／ARM64）以 framework-dependent 方式建置到 %LOCALAPPDATA%\AIUsageMonitor\WindowsApp.new。
  3. 結束執行中的 App（具名事件；5 秒後仍在才結束安裝資料夾裡的那一個），換上新版（舊版改名 WindowsApp.old）。
  4. 開機自動啟動：目前使用者的 HKCU\Software\Microsoft\Windows\CurrentVersion\Run（值 AIUsageMonitor）。
     第一次安裝預設開啟，之後依 App 的設定（windows-app.json 的 launch_at_login）。
  5. 啟動 App。
  不需要系統管理員。App 不連網、不持有密鑰，只讀收集器寫的 usage.json（收集器要以 install-task.ps1 -WithQuota 安裝）。

.PARAMETER Uninstall
  結束 App、刪除開機自動啟動與安裝資料夾。設定檔 windows-app.json 與收集器的資料保留。

.PARAMETER NoStart
  安裝後不啟動（測試用）。

.PARAMETER Yes
  需要安裝 .NET SDK 時不詢問，直接用 winget 安裝。
#>
param(
    [switch]$Uninstall,
    [switch]$NoStart,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Repo 'windows\src\AIUsageMonitor.Windows\AIUsageMonitor.Windows.csproj'
$DataDir = Join-Path $env:LOCALAPPDATA 'AIUsageMonitor'
$AppDir = Join-Path $DataDir 'WindowsApp'
$NewDir = Join-Path $DataDir 'WindowsApp.new'
$OldDir = Join-Path $DataDir 'WindowsApp.old'
$Exe = Join-Path $AppDir 'AIUsageMonitor.exe'
$Settings = Join-Path $DataDir 'windows-app.json'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'AIUsageMonitor'
$QuitEvent = 'Local\io.github.kevin930326.AIUsageMonitor.Windows.quit'

# 結束安裝資料夾裡執行中的 App：先請它自己結束（具名事件），5 秒後仍在才強制結束
function Stop-App {
    $running = @(Get-Process -Name 'AIUsageMonitor' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($AppDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -eq 0) { return }
    try {
        $handle = [Threading.EventWaitHandle]::OpenExisting($QuitEvent)
        $handle.Set() | Out-Null
        $handle.Dispose()
    } catch [Threading.WaitHandleCannotBeOpenedException] {
    }
    foreach ($p in $running) {
        if (-not $p.WaitForExit(5000)) { Stop-Process -Id $p.Id -Force }
    }
}

function Set-Autostart([bool]$Enabled) {
    if ($Enabled) {
        New-Item -Path $RunKey -Force | Out-Null
        Set-ItemProperty -Path $RunKey -Name $RunValue -Value "`"$Exe`""
    } else {
        Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
    }
}

if ($Uninstall) {
    Stop-App
    Set-Autostart $false
    foreach ($dir in @($AppDir, $NewDir, $OldDir)) { if (Test-Path $dir) { Remove-Item -Recurse -Force $dir } }
    Write-Host "已移除 Windows App（設定 $Settings 與收集器的資料保留）。"
    return
}

# ---------- .NET 10 SDK ----------
function Find-Sdk {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        $candidate = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
        if (Test-Path $candidate) { $dotnet = Get-Command $candidate }
    }
    if (-not $dotnet) { return $null }
    $sdks = & $dotnet.Source --list-sdks 2>$null
    if ($sdks | Where-Object { $_ -match '^10\.' }) { return $dotnet.Source }
    return $null
}

$Dotnet = Find-Sdk
if (-not $Dotnet) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw '找不到 .NET 10 SDK，也沒有 winget。從 https://dotnet.microsoft.com/download/dotnet/10.0 安裝 .NET 10 SDK 後重新執行。'
    }
    if (-not $Yes) {
        $answer = Read-Host '需要 .NET 10 SDK 才能建置。用 winget 安裝 Microsoft.DotNet.SDK.10 嗎？[Y/n]'
        if ($answer -and $answer -notmatch '^[Yy]') { throw '沒有安裝 .NET SDK，停止。' }
    }
    & $winget.Source install --id Microsoft.DotNet.SDK.10 --exact --source winget
    if ($LASTEXITCODE -ne 0) { throw "winget 安裝失敗（結束碼 $LASTEXITCODE）。" }
    $env:PATH = "$env:PATH;$(Join-Path $env:ProgramFiles 'dotnet')"
    $Dotnet = Find-Sdk
    if (-not $Dotnet) { throw '已安裝 .NET SDK 但找不到 dotnet，開一個新的 PowerShell 視窗後重新執行。' }
}

# ---------- 建置 ----------
$arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$Rid = if ($arch -eq [Runtime.InteropServices.Architecture]::Arm64) { 'win-arm64' } else { 'win-x64' }
Write-Host "建置 $Rid（Release）…"
if (Test-Path $NewDir) { Remove-Item -Recurse -Force $NewDir }
& $Dotnet publish $Project -c Release -r $Rid --self-contained false -p:DebugType=none -o $NewDir --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "建置失敗（結束碼 $LASTEXITCODE）。" }
if (-not (Test-Path (Join-Path $NewDir 'AIUsageMonitor.exe'))) { throw '建置結果沒有 AIUsageMonitor.exe。' }

# ---------- 換上新版 ----------
$firstInstall = -not (Test-Path $AppDir)
Stop-App
if (Test-Path $OldDir) { Remove-Item -Recurse -Force $OldDir }
if (Test-Path $AppDir) { Move-Item $AppDir $OldDir }
Move-Item $NewDir $AppDir

# 開機自動啟動：依 App 的設定，第一次安裝（沒有設定檔）時開啟
$launch = $true
if (Test-Path $Settings) {
    try {
        $json = Get-Content $Settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'launch_at_login') { $launch = [bool]$json.launch_at_login }
    } catch {
        Write-Warning "讀不到 $Settings，開機自動啟動維持開啟。"
    }
}
Set-Autostart $launch

$what = if ($firstInstall) { '已安裝' } else { '已更新' }
Write-Host "$what Windows App：$AppDir（開機自動啟動：$(if ($launch) { '開' } else { '關' })）"
if (-not (Test-Path (Join-Path $DataDir 'usage.json'))) {
    Write-Host '還沒有額度資料：在 collector 資料夾執行 windows\install-task.ps1 -WithQuota，收集器 5 分鐘內寫出 usage.json。'
}
if (-not $NoStart) { Start-Process -FilePath $Exe }
Write-Host '移除：scripts\install-windows-app.ps1 -Uninstall'
