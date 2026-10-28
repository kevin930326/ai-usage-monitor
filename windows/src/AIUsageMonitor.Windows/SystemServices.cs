using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using AIUsageMonitor.Core;
using Microsoft.Win32;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 單一執行個體與命令（ADR-0015 識別字）：Mutex 確認只有一個在跑；第二個執行個體以具名事件請第一個
/// 打開面板（.show）、收起面板（.hide，效能量測）或結束（.quit，安裝腳本更新時），然後自己結束。等待事件不輪詢。
/// aum-hook.exe 以同一個 Mutex 判斷 App 在不在跑，寫好事件檔後觸發 .agent 叫醒 App（ADR-0019 第 1 節）。
/// </summary>
internal sealed class SingleInstance : IDisposable
{
    public const string Id = "io.github.kevin930326.AIUsageMonitor.Windows";
    private const string Prefix = @"Local\" + Id;

    private readonly Mutex mutex;
    private readonly EventWaitHandle show = new(false, EventResetMode.AutoReset, Prefix + ".show");
    private readonly EventWaitHandle hide = new(false, EventResetMode.AutoReset, Prefix + ".hide");
    private readonly EventWaitHandle quit = new(false, EventResetMode.AutoReset, Prefix + ".quit");
    private readonly EventWaitHandle agent = new(false, EventResetMode.AutoReset, Prefix + ".agent");
    private RegisteredWaitHandle[] waits = [];

    public bool IsFirst { get; }

    public SingleInstance()
    {
        mutex = new Mutex(true, Prefix, out var created);
        IsFirst = created;
    }

    /// <summary>第二個執行個體：把命令交給第一個。面板要成為前景視窗，先允許對方 SetForegroundWindow</summary>
    public void Send(string command)
    {
        NativeMethods.AllowSetForegroundWindow(NativeMethods.ASFW_ANY);
        (command switch
        {
            "hide" => hide,
            "quit" => quit,
            _ => show,
        }).Set();
    }

    public void Listen(Dispatcher dispatcher, Action onShow, Action onHide, Action onQuit, Action onAgent)
    {
        RegisteredWaitHandle Register(WaitHandle handle, Action action) =>
            ThreadPool.RegisterWaitForSingleObject(handle, (_, _) => dispatcher.BeginInvoke(action), null, Timeout.Infinite, false);
        waits = [Register(show, onShow), Register(hide, onHide), Register(quit, onQuit), Register(agent, onAgent)];
    }

    public void Dispose()
    {
        foreach (var w in waits) w.Unregister(null);
        if (IsFirst) mutex.ReleaseMutex();
        mutex.Dispose();
        show.Dispose();
        hide.Dispose();
        quit.Dispose();
        agent.Dispose();
    }
}

/// <summary>
/// 隔離模式（命令列 <c>--isolated</c>；Debug 的示範與截圖也會設定）：不改開機自動啟動、不觸發收集器，給測試與效能量測用。
/// <c>AI_USAGE_MONITOR_HOME</c> 只決定資料夾（和收集器相同），不代表測試：使用者把資料放在別處時一切照常。
/// </summary>
internal static class AppMode
{
    public static bool Isolated { get; set; }
}

/// <summary>開機自動啟動：目前使用者的 HKCU\…\Run（值 AIUsageMonitor），不需要系統管理員。</summary>
internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "AIUsageMonitor";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    public static void Set(bool enabled)
    {
        // 測試、截圖、效能量測（--isolated）不改真正的開機項目
        if (AppMode.Isolated) return;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled && Environment.ProcessPath is { } exe) key.SetValue(ValueName, $"\"{exe}\"");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            AppLog.Write($"autostart: {e.GetType().Name}");
        }
    }
}

/// <summary>
/// 「立即更新」：請工作排程器提早執行收集器（\AIUsageMonitor\Collector，Mac 的 launchctl kickstart，FR-50）。
/// App 本身不連網；連網的是收集器。這是 App 唯一啟動其他程式的地方（ADR-0015 第 2 節，CI 靜態檢查）。
/// </summary>
internal sealed class CollectorTrigger
{
    private const string TaskName = @"\AIUsageMonitor\Collector";
    private readonly AppSettings settings;
    private bool running;

    public CollectorTrigger(AppSettings settings) => this.settings = settings;

    public async Task<RefreshOutcome> TriggerAsync()
    {
        // 測試、截圖、效能量測（--isolated）不碰真的收集器
        if (AppMode.Isolated) return RefreshOutcome.Skipped;
        var now = DateTimeOffset.Now;
        var throttle = new CollectorKickThrottle(settings.CollectorKicks);
        switch (throttle.DecisionAt(now))
        {
            case CollectorKickThrottle.Decision.TooSoon: return RefreshOutcome.TooSoon;
            case CollectorKickThrottle.Decision.DailyLimitReached: return RefreshOutcome.DailyLimitReached;
        }
        if (running) return RefreshOutcome.TooSoon;
        running = true;
        try
        {
            // 先記錄再執行：就算失敗，60 秒內也不會連續重試
            throttle.Record(now);
            settings.CollectorKicks = [.. throttle.Kicks];
            SettingsFile.Save(settings);
            if (await RunAsync("/Query", "/TN", TaskName) != 0) return RefreshOutcome.NotInstalled;
            var code = await RunAsync("/Run", "/TN", TaskName);
            AppLog.Write($"schtasks /Run exit={code}");
            return code == 0 ? RefreshOutcome.Started : RefreshOutcome.Failed;
        }
        finally
        {
            running = false;
        }
    }

    internal static async Task<int?> RunAsync(params string[] args)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        try
        {
            using var process = Process.Start(info);
            if (process is null) return null;
            // 輸出不顯示也不記錄（只看結束碼）
            var drain = Task.WhenAll(process.StandardOutput.ReadToEndAsync(), process.StandardError.ReadToEndAsync());
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await process.WaitForExitAsync(timeout.Token);
            await drain;
            return process.ExitCode;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or OperationCanceledException or InvalidOperationException)
        {
            AppLog.Write($"schtasks: {e.GetType().Name}");
            return null;
        }
    }
}

/// <summary>
/// AI 狀態同步（ADR-0019 第 2 節）：App 寫了 agent-state.json 後請工作排程器執行 \AIUsageMonitor\AgentSync
/// （install-task.ps1 建立，沒有觸發條件）。不受「立即更新」的節流限制，收集器自己最短 60 秒同步一次；
/// 沒有安裝這個排程時 schtasks 失敗、不影響。App 本身仍不連網。
/// </summary>
internal static class AgentSyncTrigger
{
    private const string TaskName = @"\AIUsageMonitor\AgentSync";
    private static bool running;

    public static async void Run()
    {
        if (AppMode.Isolated || running) return;
        running = true;
        try
        {
            var code = await CollectorTrigger.RunAsync("/Run", "/TN", TaskName);
            if (code != 0) AppLog.Write($"agent sync schtasks /Run exit={code?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "null"}");
        }
        finally
        {
            running = false;
        }
    }

    /// <summary>App 結束時：不等結果（結束前送出就好）</summary>
    public static void RunAndForget()
    {
        if (AppMode.Isolated) return;
        _ = CollectorTrigger.RunAsync("/Run", "/TN", TaskName);
    }
}
