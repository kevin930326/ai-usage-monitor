<#
.SYNOPSIS
  Windows App 的效能量測（ADR-0015 第 7 節，Mac 的 scripts/measure-panel-perf.sh）。

.DESCRIPTION
  AI_USAGE_MONITOR_HOME 指到暫存資料夾、放一份示範的 usage.json（不碰真實資料），啟動 App（Release 版也可以），
  以 Get-Process 取樣 CPU 與記憶體：
    - 閒置（圓環顯示、面板關閉）30 秒
    - 打開面板（第二個執行個體送 --show-panel）：前 2 秒（動畫）每 0.25 秒取樣記最大值，之後靜止 10 秒
    - 關閉面板（--hide-panel）後等 60 秒，再取樣 30 秒
    - 再開關 5 次，比較第一次與最後一次關閉後的記憶體
  CPU% ＝ TotalProcessorTime 的差 ÷ 經過時間 ÷ 處理器數 × 100（工作管理員的算法）。
  結果印成 Markdown 表格，並寫到 -Output。CPU 超過門檻只印警告（CI 的 runner 雜訊大；正式紀錄以 x64 桌機為準），記憶體增加超過 5 MB 時結束碼 1。

.PARAMETER Exe
  AIUsageMonitor.exe 的路徑。

.PARAMETER Output
  結果的 Markdown 檔。

.PARAMETER Ci
  用 CI 的警告門檻（ADR-0015 第 7 節：閒置 0.3%、面板靜止 4%、關閉後 0.6%）；沒有時用桌機的門檻（0.1%、2%、0.3%）。
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Output = 'perf.md',
    [switch]$Ci
)
$ErrorActionPreference = 'Stop'

$home2 = Join-Path ([IO.Path]::GetTempPath()) ('aum-perf-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$now = [DateTime]::UtcNow
function Iso([double]$hours) { $now.AddHours($hours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
$usage = @"
{"schema_version": 1, "updated_at": "$(Iso -0.05)", "providers": {
  "claude": {"plan": "Max", "windows": [
    {"id": "five_hour", "label": "5 小時", "used_pct": 60, "resets_at": "$(Iso 3.5)"},
    {"id": "weekly", "label": "每週", "used_pct": 37, "resets_at": "$(Iso 98)"}]},
  "codex": {"plan": "Plus", "windows": [
    {"id": "five_hour", "label": "5 小時", "used_pct": 10, "resets_at": "$(Iso 4.1)"},
    {"id": "weekly", "label": "每週", "used_pct": 22, "resets_at": "$(Iso 130)"}]}}}
"@
[IO.File]::WriteAllText((Join-Path $home2 'usage.json'), $usage, (New-Object Text.UTF8Encoding($false)))
$cores = [Environment]::ProcessorCount

# 面板是否真的開著：找這個程序、標題 "AI Usage Monitor"、看得見的頂層視窗（面板關閉＝視窗銷毀）
Add-Type -Namespace AumPerf -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
public static bool PanelVisible(int pid) {
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowExW(IntPtr.Zero, h, null, "AI Usage Monitor")) != IntPtr.Zero) {
        uint owner; GetWindowThreadProcessId(h, out owner);
        if (owner == pid && IsWindowVisible(h)) return true;
    }
    return false;
}
'@

# 環境變數只在量測期間指到暫存資料夾，結束（含失敗）時還原，App 結束、暫存資料夾刪除
$previousHome = $env:AI_USAGE_MONITOR_HOME
$app = $null
try {
    $env:AI_USAGE_MONITOR_HOME = $home2
    # --isolated：不改開機自動啟動、不觸發收集器
    $app = Start-Process -FilePath $Exe -ArgumentList '--isolated' -PassThru
    Start-Sleep -Seconds 10
    if ($app.HasExited) { throw "App exited early (code $($app.ExitCode))" }

    function Sample([double]$seconds) {
        $app.Refresh()
        $cpu0 = $app.TotalProcessorTime.TotalSeconds
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds ([int]($seconds * 1000))
        $app.Refresh()
        $cpu = ($app.TotalProcessorTime.TotalSeconds - $cpu0) / $t0.Elapsed.TotalSeconds / $cores * 100
        [pscustomobject]@{ Cpu = [Math]::Round($cpu, 3); WorkingSetMB = [Math]::Round($app.WorkingSet64 / 1MB, 1); PrivateMB = [Math]::Round($app.PrivateMemorySize64 / 1MB, 1) }
    }
    # 第二個執行個體送命令，再確認面板真的打開或關閉（5 秒內），否則量測失敗
    function Send([string]$arg, [bool]$open) {
        Start-Process -FilePath $Exe -ArgumentList $arg -Wait | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([AumPerf.Win]::PanelVisible($app.Id) -ne $open) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "panel did not $(if ($open) { 'open' } else { 'close' }) after $arg" }
            Start-Sleep -Milliseconds 100
        }
    }
    function PeakDuring([double]$seconds) {
        $max = 0
        $n = [int]($seconds / 0.25)
        for ($i = 0; $i -lt $n; $i++) { $s = Sample 0.25; if ($s.Cpu -gt $max) { $max = $s.Cpu } }
        $max
    }

    $idle = Sample 30
    Send '--show-panel' $true
    $peak = PeakDuring 2
    $open = Sample 10
    Send '--hide-panel' $false
    Start-Sleep -Seconds 60
    $after = Sample 30
    $memFirst = $after.WorkingSetMB
    for ($i = 0; $i -lt 5; $i++) {
        Send '--show-panel' $true
        Start-Sleep -Seconds 2
        Send '--hide-panel' $false
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 20
    $last = Sample 10
    $memGrowth = [Math]::Round($last.WorkingSetMB - $memFirst, 1)

    Start-Process -FilePath $Exe -ArgumentList '--quit' -Wait | Out-Null
    Start-Sleep -Seconds 3
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
    $env:AI_USAGE_MONITOR_HOME = $previousHome
    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
}

$limits = if ($Ci) { 0.3, 4, 0.6 } else { 0.1, 2, 0.3 }
$rows = @(
    @('閒置（圓環顯示、面板關閉）', $idle.Cpu, $limits[0], $idle.WorkingSetMB),
    @('面板開啟、動畫中（最大值）', $peak, $null, $open.WorkingSetMB),
    @('面板開啟、靜止', $open.Cpu, $limits[1], $open.WorkingSetMB),
    @('關閉後 1 分鐘', $after.Cpu, $limits[2], $after.WorkingSetMB)
)
$lines = @('| 狀態 | CPU % | 門檻 | 工作集 MB |', '|---|---|---|---|')
$warnings = @()
foreach ($r in $rows) {
    $limit = if ($null -ne $r[2]) { "≤ $($r[2])" } else { '記錄' }
    $lines += "| $($r[0]) | $($r[1]) | $limit | $($r[3]) |"
    if ($null -ne $r[2] -and $r[1] -gt $r[2]) { $warnings += "$($r[0]): $($r[1])% > $($r[2])%" }
}
$lines += "| 重複開關 5 次後的記憶體增加 | — | ≤ +5 MB | $memGrowth |"
if ($memGrowth -gt 5) { $warnings += "memory grew $memGrowth MB" }
$lines += ''
$lines += "處理器 $cores 個；$([Environment]::OSVersion.VersionString)；$((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)"
$text = $lines -join "`n"
[IO.File]::WriteAllText($Output, $text + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host $text
foreach ($w in $warnings) { Write-Host "::warning::perf $w" }
if ($memGrowth -gt 5) { exit 1 }
