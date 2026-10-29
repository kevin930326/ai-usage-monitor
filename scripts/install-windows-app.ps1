<#
.SYNOPSIS
  從 repo 建置並安裝 Windows 桌面 App（ADR-0015 第 8 節）；-FromRelease 改成從 GitHub Release 下載。再執行一次＝更新；-Uninstall 移除。

.DESCRIPTION
  1. 找 .NET 10 SDK（dotnet --list-sdks）；沒有時詢問一次，用 winget 安裝 Microsoft.DotNet.SDK.10（目前使用者確認 winget 的協議）。
  2. 依這台電腦的架構（x64／ARM64）以 framework-dependent 方式建置到 %LOCALAPPDATA%\AIUsageMonitor\WindowsApp.new。
  3. 結束執行中的 App（具名事件；5 秒後仍在才結束安裝資料夾裡的那一個），換上新版（舊版改名 WindowsApp.old）。
  4. 開機自動啟動：目前使用者的 HKCU\Software\Microsoft\Windows\CurrentVersion\Run（值 AIUsageMonitor）。
     第一次安裝預設開啟，之後依 App 的設定（windows-app.json 的 launch_at_login）。
  5. 啟動 App。
  不需要系統管理員。App 不連網、不持有密鑰，只讀收集器寫的 usage.json（收集器要以 install-task.ps1 -WithQuota 安裝）。

  -FromRelease：不用 .NET SDK、不建置。從 GitHub Release 下載這台電腦架構的自含式 zip（AIUsageMonitor-windows-<x64|arm64>-<版本>.zip）
  與 SHA256SUMS-windows，SHA-256 一致才解除封鎖（Zone.Identifier）、解壓並照上面第 3～5 步安裝；不一致或清單裡沒有這個檔案就停，
  不動目前安裝的版本。只有這個模式會連網（腳本本身，不是 App）。

.PARAMETER Uninstall
  結束 App、刪除開機自動啟動與安裝資料夾。設定檔 windows-app.json 與收集器的資料保留。

.PARAMETER NoStart
  安裝後不啟動（測試用）。

.PARAMETER Yes
  需要安裝 .NET SDK 時不詢問，直接用 winget 安裝。

.PARAMETER FromRelease
  從 GitHub Release 下載（見上面）。

.PARAMETER Version
  -FromRelease 的版本（例如 1.0.0）；沒有時用最新發布的版本（GitHub API 的 releases/latest）。

.PARAMETER ReleaseDir
  -FromRelease 時改從這個資料夾讀 zip 與 SHA256SUMS-windows，不下載（測試與離線安裝；要同時給 -Version）。
#>
param(
    [switch]$Uninstall,
    [switch]$NoStart,
    [switch]$Yes,
    [switch]$FromRelease,
    [string]$Version,
    [string]$ReleaseDir
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
$ReleaseRepo = 'kevin930326/ai-usage-monitor'

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

$arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$Rid = if ($arch -eq [Runtime.InteropServices.Architecture]::Arm64) { 'win-arm64' } else { 'win-x64' }

if ($FromRelease) {
    # ---------- 從 GitHub Release 下載（比對 SHA-256 後才解除封鎖） ----------
    if ($ReleaseDir -and -not $Version) { throw '-ReleaseDir 要同時給 -Version。' }
    if (-not $ReleaseDir) {
        # Windows PowerShell 5.1 預設可能沒開 TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    if (-not $Version) {
        $latest = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$ReleaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'ai-usage-monitor-installer' }
        $Version = "$($latest.tag_name)" -replace '^v', ''
    }
    if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$') { throw "版本格式不對：$Version" }
    $zipName = "AIUsageMonitor-windows-$($Rid -replace '^win-', '')-$Version.zip"
    $download = Join-Path ([IO.Path]::GetTempPath()) ('aum-release-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $download | Out-Null
    try {
        $zip = Join-Path $download $zipName
        $sums = Join-Path $download 'SHA256SUMS-windows'
        if ($ReleaseDir) {
            Copy-Item (Join-Path $ReleaseDir $zipName) $zip
            Copy-Item (Join-Path $ReleaseDir 'SHA256SUMS-windows') $sums
        } else {
            $base = "https://github.com/$ReleaseRepo/releases/download/v$Version"
            Write-Host "下載 $zipName（v$Version）…"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$zipName" -OutFile $zip
            Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS-windows" -OutFile $sums
        }
        # SHA256SUMS-windows：「<64 個十六進位>  <檔名>」一行一個
        $expected = $null
        foreach ($line in Get-Content $sums) {
            if ($line -match '^([0-9a-fA-F]{64})  (.+)$' -and $Matches[2] -eq $zipName) { $expected = $Matches[1].ToLower() }
        }
        if (-not $expected) { throw "SHA256SUMS-windows 裡沒有 $zipName，停止（沒有安裝）。" }
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) { throw "SHA-256 不一致（$zipName：預期 $expected，實際 $actual），停止（沒有安裝）。" }
        Write-Host "SHA-256 一致：$actual"
        # 一致才解除封鎖：zip 與解出來的檔案都拿掉「從網路下載」的標記（SmartScreen 不再擋這個版本）
        Unblock-File $zip
        $extract = Join-Path $download 'extract'
        Expand-Archive -Path $zip -DestinationPath $extract
        $inner = Join-Path $extract 'AIUsageMonitor'
        if (-not (Test-Path (Join-Path $inner 'AIUsageMonitor.exe'))) { throw "$zipName 裡沒有 AIUsageMonitor\AIUsageMonitor.exe，停止（沒有安裝）。" }
        Get-ChildItem $inner -Recurse -File | Unblock-File
        # 第一次安裝、也沒裝過收集器的電腦還沒有資料夾
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        if (Test-Path $NewDir) { Remove-Item -Recurse -Force $NewDir }
        Move-Item $inner $NewDir
    } finally {
        Remove-Item -Recurse -Force $download -ErrorAction SilentlyContinue
    }
} else {
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
    Write-Host "建置 $Rid（Release）…"
    if (Test-Path $NewDir) { Remove-Item -Recurse -Force $NewDir }
    & $Dotnet publish $Project -c Release -r $Rid --self-contained false -p:DebugType=none -o $NewDir --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "建置失敗（結束碼 $LASTEXITCODE）。" }
    if (-not (Test-Path (Join-Path $NewDir 'AIUsageMonitor.exe'))) { throw '建置結果沒有 AIUsageMonitor.exe。' }
}

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
