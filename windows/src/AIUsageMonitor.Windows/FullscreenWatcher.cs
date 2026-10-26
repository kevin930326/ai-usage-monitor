using System;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 圓環所在的螢幕有全螢幕 App 時通知隱藏（ADR-0015 第 6 節），事件驅動、不輪詢：
/// - 前景視窗改變（EVENT_SYSTEM_FOREGROUND，全系統、略過自己的程序）
/// - 前景視窗本身移動、改變大小或關閉（只掛在前景視窗的程序上；前景改變時換掛）：同一個視窗按 F11 進入或離開全螢幕
/// 事件 250 ms 內合併成一次判斷。判斷規則在 UsageCore 的 <see cref="FullscreenRule"/>。
/// </summary>
internal sealed class FullscreenWatcher : IDisposable
{
    private readonly Func<IntPtr> ringWindow;
    private readonly DispatcherTimer coalesce;
    // 回呼要一直被參考，否則 GC 後系統呼叫已回收的委派
    private readonly NativeMethods.WinEventProc foregroundProc;
    private readonly NativeMethods.WinEventProc locationProc;
    private IntPtr foregroundHook;
    private IntPtr locationHook;
    private IntPtr destroyHook;
    private uint watchedProcess;
    private IntPtr foreground;

    public bool IsFullscreen { get; private set; }
    public event Action? Changed;

    public FullscreenWatcher(Dispatcher dispatcher, Func<IntPtr> ringWindow)
    {
        this.ringWindow = ringWindow;
        coalesce = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
        coalesce.Tick += (_, _) =>
        {
            coalesce.Stop();
            Evaluate();
        };
        foregroundProc = OnForeground;
        locationProc = OnLocation;
    }

    public void Start()
    {
        if (foregroundHook != IntPtr.Zero) return;
        foregroundHook = NativeMethods.SetWinEventHook(NativeMethods.EVENT_SYSTEM_FOREGROUND, NativeMethods.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
                                                       foregroundProc, 0, 0, NativeMethods.WINEVENT_OUTOFCONTEXT | NativeMethods.WINEVENT_SKIPOWNPROCESS);
        Evaluate();
    }

    public void Stop()
    {
        coalesce.Stop();
        Unhook(ref foregroundHook);
        Unhook(ref locationHook);
        Unhook(ref destroyHook);
        watchedProcess = 0;
        if (IsFullscreen)
        {
            IsFullscreen = false;
            Changed?.Invoke();
        }
    }

    /// <summary>前景視窗改變時也要讓圓環重新排到最上層（其他 topmost 視窗可能蓋住它）</summary>
    public event Action? ForegroundChanged;

    private void OnForeground(IntPtr hook, uint eventType, IntPtr hWnd, int idObject, int idChild, uint thread, uint time)
    {
        ForegroundChanged?.Invoke();
        Schedule();
    }

    private void OnLocation(IntPtr hook, uint eventType, IntPtr hWnd, int idObject, int idChild, uint thread, uint time)
    {
        // 只看前景視窗本身（同一個程序的其他視窗、游標、插入點的事件不理）
        if (idObject == NativeMethods.OBJID_WINDOW && idChild == 0 && hWnd == foreground) Schedule();
    }

    private void Schedule()
    {
        if (!coalesce.IsEnabled) coalesce.Start();
    }

    private void Evaluate()
    {
        foreground = NativeMethods.GetForegroundWindow();
        WatchProcessOf(foreground);
        var now = Compute();
        if (now == IsFullscreen) return;
        IsFullscreen = now;
        Changed?.Invoke();
    }

    private bool Compute()
    {
        var ring = ringWindow();
        if (ring == IntPtr.Zero) return false;
        var ringMonitor = NativeMethods.Monitor(NativeMethods.MonitorFromWindow(ring, NativeMethods.MONITOR_DEFAULTTONEAREST));
        if (ringMonitor is null) return false;
        // 獨占全螢幕的 D3D 或簡報模式
        if (NativeMethods.SHQueryUserNotificationState(out var state) == 0 && FullscreenRule.IsExclusiveFullscreen(state)) return true;
        if (foreground == IntPtr.Zero || foreground == ring) return false;
        NativeMethods.GetWindowThreadProcessId(foreground, out var pid);
        if (pid == (uint)Environment.ProcessId) return false;
        var monitor = NativeMethods.Monitor(NativeMethods.MonitorFromWindow(foreground, NativeMethods.MONITOR_DEFAULTTONEAREST));
        if (monitor is null) return false;
        return FullscreenRule.IsFullscreen(NativeMethods.ClassName(foreground), NativeMethods.IsCloaked(foreground),
                                           NativeMethods.FrameBounds(foreground), monitor, ringMonitor,
                                           NativeMethods.IsMaximizedWithCaption(foreground));
    }

    private void WatchProcessOf(IntPtr window)
    {
        uint pid = 0;
        if (window != IntPtr.Zero) NativeMethods.GetWindowThreadProcessId(window, out pid);
        if (pid == (uint)Environment.ProcessId) pid = 0;
        if (pid == watchedProcess) return;
        Unhook(ref locationHook);
        Unhook(ref destroyHook);
        watchedProcess = pid;
        if (pid == 0) return;
        // 兩個事件分開掛：中間的範圍（名稱、狀態、焦點…）在瀏覽器裡很頻繁，不需要
        locationHook = NativeMethods.SetWinEventHook(NativeMethods.EVENT_OBJECT_LOCATIONCHANGE, NativeMethods.EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero,
                                                     locationProc, pid, 0, NativeMethods.WINEVENT_OUTOFCONTEXT);
        destroyHook = NativeMethods.SetWinEventHook(NativeMethods.EVENT_OBJECT_DESTROY, NativeMethods.EVENT_OBJECT_DESTROY, IntPtr.Zero,
                                                    locationProc, pid, 0, NativeMethods.WINEVENT_OUTOFCONTEXT);
    }

    private static void Unhook(ref IntPtr hook)
    {
        if (hook == IntPtr.Zero) return;
        NativeMethods.UnhookWinEvent(hook);
        hook = IntPtr.Zero;
    }

    public void Dispose() => Stop();
}
