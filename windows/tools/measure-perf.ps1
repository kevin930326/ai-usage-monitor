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
    - 滑鼠移到圓環上（SetCursorPos）：展開動畫 1 秒記最大值、展開後靜止 5 秒；移開後收起動畫 1.5 秒記最大值，收起後 30 秒再取樣
      （以圓環視窗變寬、收起後回到原寬確認；沒確認到時不列這幾行。-Ci 時只記「未量到」，桌機上算量測失敗）
    - 角色（預設的圖示樣式，ADR-0015 第 7 節「角色」）：上面的「閒置」是收合、沒在動（含每秒 4 次讀游標），「展開、靜止」是展開待著；
      另外量收合時 AI 工作中（每 5 秒改一次假的紀錄檔，等收著時每 60 秒一次的檢查看到後取樣 30 秒）與收合睡著
      （紀錄檔改成 31 分鐘前，等下一次檢查後取樣 30 秒）。--isolated 時 AI 的設定資料夾在暫存資料夾的 .claude，不碰真的 ~/.claude
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
# 角色：睡覺的分鐘數設最長（30），閒置時是「醒著、沒在工作」；假的紀錄檔 2 分鐘前改過（不是工作中）
[IO.File]::WriteAllText((Join-Path $home2 'windows-app.json'), '{"ring_style": "mascot", "mascot_sleep_minutes": 30}', (New-Object Text.UTF8Encoding($false)))
$log = Join-Path $home2 '.claude\projects\demo\session.jsonl'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
[IO.File]::WriteAllText($log, '{}')
(Get-Item $log).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-2)
$cores = [Environment]::ProcessorCount

# 面板是否真的開著：找這個程序、標題 "AI Usage Monitor"、看得見的頂層視窗（面板關閉＝視窗銷毀）
Add-Type -Namespace AumPerf -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
public static IntPtr Find(int pid, string title) {
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowExW(IntPtr.Zero, h, null, title)) != IntPtr.Zero) {
        uint owner; GetWindowThreadProcessId(h, out owner);
        if (owner == pid && IsWindowVisible(h)) return h;
    }
    return IntPtr.Zero;
}
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

    # 滑鼠移上去展開、移開收起
    $hoverNote = '未展開（找不到圓環或滑鼠移動沒有送到）'
    $hoverPeak = $null; $hoverOpen = $null; $collapsePeak = $null; $afterHover = $null
    $ring = [AumPerf.Win]::Find($app.Id, 'AI Usage Monitor Ring')
    if ($ring -ne [IntPtr]::Zero) {
        $r0 = New-Object AumPerf.Win+RECT
        [void][AumPerf.Win]::GetWindowRect($ring, [ref]$r0)
        [void][AumPerf.Win]::SetCursorPos([int](($r0.Left + $r0.Right) / 2), [int](($r0.Top + $r0.Bottom) / 2))
        $hoverPeak = PeakDuring 1
        # 角色第一次展開有過場（約 4.7 秒）：播完再量待著
        Start-Sleep -Seconds 5
        $r1 = New-Object AumPerf.Win+RECT
        [void][AumPerf.Win]::GetWindowRect($ring, [ref]$r1)
        $hoverOpen = Sample 5
        [void][AumPerf.Win]::SetCursorPos(5, 5)
        $collapsePeak = PeakDuring 1.5
        $r2 = New-Object AumPerf.Win+RECT
        [void][AumPerf.Win]::GetWindowRect($ring, [ref]$r2)
        Start-Sleep -Seconds 30
        $afterHover = Sample 30
        $w0 = $r0.Right - $r0.Left; $w1 = $r1.Right - $r1.Left; $w2 = $r2.Right - $r2.Left
        if ($w1 -gt $w0 -and $w2 -eq $w0) {
            $hoverNote = "展開（視窗寬 $w0 → $w1 → 收起後 $w2 px）"
        } else {
            $hoverNote = "未量到：展開或收起沒有確認（視窗寬 $w0 → $w1 → $w2 px）"
            $hoverOpen = $null
        }
    }

    # 角色：收合時 AI 工作中（敲鍵盤的一輪，每秒 12 格）
    function Touch { (Get-Item $log).LastWriteTimeUtc = [DateTime]::UtcNow }
    function SampleTouching([int]$seconds) {
        $sum = 0; $n = [int]($seconds / 5)
        for ($i = 0; $i -lt $n; $i++) { Touch; $sum += (Sample 5).Cpu }
        [Math]::Round($sum / $n, 3)
    }
    [void][AumPerf.Win]::SetCursorPos(5, 5)
    [void](SampleTouching 70)
    $working = SampleTouching 30
    # 收合睡著（呼吸的一輪，每秒 4 格）：紀錄檔改成 31 分鐘前，等下一次檢查
    (Get-Item $log).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-31)
    Start-Sleep -Seconds 70
    $sleeping = Sample 30

    Start-Process -FilePath $Exe -ArgumentList '--quit' -Wait | Out-Null
    Start-Sleep -Seconds 3
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
    $env:AI_USAGE_MONITOR_HOME = $previousHome
    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
}

$limits = if ($Ci) { 0.3, 4, 0.6 } else { 0.1, 2, 0.3 }
$rows = @(
    @('閒置（角色收合、沒在動、面板關閉）', $idle.Cpu, $limits[0], $idle.WorkingSetMB),
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
if ($null -ne $hoverOpen) {
    $lines += "| 圖示展開動畫中（最大值） | $hoverPeak | 記錄 | — |"
    $lines += "| 圖示展開待著（角色眨眼、看滑鼠） | $($hoverOpen.Cpu) | ≤ $($limits[1]) | $($hoverOpen.WorkingSetMB) |"
    $lines += "| 圖示收起動畫中（最大值） | $collapsePeak | 記錄 | — |"
    $lines += "| 收起後（30 秒後） | $($afterHover.Cpu) | ≤ $($limits[2]) | $($afterHover.WorkingSetMB) |"
    if ($hoverOpen.Cpu -gt $limits[1]) { $warnings += "ring expanded: $($hoverOpen.Cpu)% > $($limits[1])%" }
    if ($afterHover.Cpu -gt $limits[2]) { $warnings += "after ring collapse: $($afterHover.Cpu)% > $($limits[2])%" }
}
$lines += "| 角色收合、AI 工作中（每秒 12 格） | $working | 記錄（目標 ≤ 1） | — |"
$lines += "| 角色收合、睡著（每秒 4 格） | $($sleeping.Cpu) | 記錄（目標 ≤ 1） | $($sleeping.WorkingSetMB) |"
if ($working -gt 1) { $warnings += "mascot working: $working% > 1%" }
if ($sleeping.Cpu -gt 1) { $warnings += "mascot sleeping: $($sleeping.Cpu)% > 1%" }
$lines += ''
$lines += "滑鼠移上去：$hoverNote"
if ($memGrowth -gt 5) { $warnings += "memory grew $memGrowth MB" }
$lines += ''
$lines += "處理器 $cores 個；$([Environment]::OSVersion.VersionString)；$((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)"
$text = $lines -join "`n"
[IO.File]::WriteAllText($Output, $text + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host $text
foreach ($w in $warnings) { Write-Host "::warning::perf $w" }
if ($memGrowth -gt 5) { exit 1 }
# 桌機（不是 -Ci）上滑鼠移上去一定要量到；CI 的工作階段不一定送得到滑鼠移動
if ($null -eq $hoverOpen -and -not $Ci) { Write-Host 'hover expansion was not measured'; exit 1 }
