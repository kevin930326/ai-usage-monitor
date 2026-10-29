using System;
using System.Runtime.InteropServices;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 前景程式改變（ADR-0017 第 8 節）：SetWinEventHook(EVENT_SYSTEM_FOREGROUND)，前景改變時才呼叫，不輪詢。
/// 只取前景視窗所屬程序的<b>執行檔名稱</b>（完整路徑拿到就丟），不讀視窗標題或內容，不寫日誌。
/// 回呼在建立它的 UI 執行緒（有訊息迴圈）上執行；提權的程式打不開（名稱是空的，不算宿主）
/// </summary>
internal sealed class AgentForeground : IDisposable
{
    private const uint EventSystemForeground = 0x0003;
    private const uint OutOfContext = 0x0000, SkipOwnProcess = 0x0002;
    private readonly WinEventProc callback;
    private readonly IntPtr hook;
    private readonly Action<string> changed;

    public AgentForeground(Action<string> changed)
    {
        this.changed = changed;
        // 委派要一直留著參考，否則被回收後系統呼叫到已釋放的位址（Fable F-18）
        callback = (_, _, hwnd, _, _, _, _) => this.changed(NameOf(hwnd));
        hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, IntPtr.Zero, callback, 0, 0, OutOfContext | SkipOwnProcess);
    }

    /// <summary>目前前景程式的執行檔名稱（啟動時用）</summary>
    public static string Current() => NameOf(GetForegroundWindow());

    private static string NameOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || GetWindowThreadProcessId(hwnd, out var pid) == 0 || pid == Environment.ProcessId) return "";
        return AgentProcessTree.ImageName((int)pid);
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
    }

    private delegate void WinEventProc(IntPtr hook, uint e, IntPtr hwnd, int obj, int child, uint thread, uint time);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
}
