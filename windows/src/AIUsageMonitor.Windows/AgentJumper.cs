using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 點工作階段跳回那個 session（ADR-0017 第 10 節）：把 AI 所在的程式（Windows Terminal、傳統主控台、VS Code、Claude App）帶到前面。
/// 只在點的那一刻找（背景執行緒）：程序的父 PID、開始時間、執行檔名稱，與可見、沒有擁有者的頂層視窗屬於哪個 PID。
/// 不讀視窗標題、不送訊息到別的視窗（不用 SendMessage、AttachThreadInput），不安裝鉤子、不注入。Windows Terminal 只帶到前面、不切分頁
/// </summary>
internal static class AgentJumper
{
    /// <summary>done 收到是否帶到前面了（false：找不到，呼叫端顯示提示）</summary>
    public static void Jump(AgentMonitor agents, AgentKind ai, string session, Dispatcher dispatcher, Action<bool> done)
    {
        var pid = agents.Sessions.Ordered(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
            .Find(s => s.Ai == ai && s.Id == session)?.Pid ?? 0;
        if (pid <= 0)
        {
            AppLog.Write("agent jump: no process");
            done(false);
            return;
        }
        var start = agents.PidStart(pid);
        var hosts = agents.Hosts;
        Task.Run(() => Find(pid, start, hosts)).ContinueWith(task => dispatcher.BeginInvoke(() =>
        {
            var window = task.IsCompletedSuccessfully ? task.Result : IntPtr.Zero;
            if (window == IntPtr.Zero)
            {
                AppLog.Write("agent jump: no host");
                done(false);
                return;
            }
            Bring(window);
            done(true);
        }));
    }

    private static IntPtr Find(int pid, long? start, AgentHosts hosts)
    {
        var names = AgentProcessTree.Names();
        var windows = TopWindows();
        AgentJump.Process? Process(int id) =>
            names.TryGetValue(id, out var entry) && AgentProcessTree.Start(id) is { } begun
                ? new AgentJump.Process(id, entry.Parent, begun, entry.Name, windows.ContainsKey(id))
                : null;
        return AgentJump.WindowsTarget(pid, start, hosts, Process) is { } target ? windows[target] : IntPtr.Zero;
    }

    /// <summary>可見、沒有擁有者的頂層視窗：PID → 第一個（Z 順序最上面的）</summary>
    private static Dictionary<int, IntPtr> TopWindows()
    {
        var result = new Dictionary<int, IntPtr>();
        NativeMethods.EnumWindows((hwnd, _) =>
        {
            if (NativeMethods.IsWindowVisible(hwnd) && NativeMethods.GetWindow(hwnd, NativeMethods.GW_OWNER) == IntPtr.Zero)
            {
                NativeMethods.GetWindowThreadProcessId(hwnd, out var owner);
                result.TryAdd((int)owner, hwnd);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    /// <summary>最小化的先還原，再設成前景；前景鎖擋下時（例如點氣球通知時 App 不是前景）閃工作列按鈕</summary>
    private static void Bring(IntPtr window)
    {
        if (NativeMethods.IsIconic(window)) NativeMethods.ShowWindow(window, NativeMethods.SW_RESTORE);
        if (NativeMethods.SetForegroundWindow(window))
        {
            AppLog.Write("agent jump: window");
            return;
        }
        var flash = new NativeMethods.FLASHWINFO
        {
            Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.FLASHWINFO>(),
            Window = window,
            Flags = NativeMethods.FLASHW_TRAY | NativeMethods.FLASHW_TIMERNOFG,
        };
        NativeMethods.FlashWindowEx(ref flash);
        AppLog.Write("agent jump: flash");
    }
}
