using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace AIUsageMonitor.Core;

/// <summary>
/// AI 程序底下的子孫程序（ADR-0017 第 7 節，同 Swift 的 AgentProcessTree）：只用程序是否存在、PID、父 PID、建立時間；hook 端另外讀
/// 父程序的<b>執行檔名稱</b>判斷是不是 shell。不讀命令列參數、環境變數、工作目錄或任何內容；結果只放在記憶體。
/// 開始時間的單位是微秒（FILETIME ÷ 10），只在同一台電腦上比較
/// </summary>
[SupportedOSPlatform("windows")]
public static class AgentProcessTree
{
    /// <summary>
    /// 執行 hook 的 shell：Codex 的 hook 是一行指令，經 cmd 或 PowerShell 執行（Fable F-04）；Claude Code 是 exec 形式，父程序就是 AI
    /// （npm 安裝的 claude.cmd 會再多一層 cmd）
    /// </summary>
    public static readonly HashSet<string> Shells = new(StringComparer.OrdinalIgnoreCase)
    {
        "cmd.exe", "powershell.exe", "pwsh.exe", "bash.exe", "sh.exe",
    };
    public const int MaxDepth = 16;

    /// <summary>hook 端：AI 程序的 PID。父程序是 shell 就往上一層（最多兩層）；找不到時回傳 0（不偵測背景工作）</summary>
    public static int AiProcess()
    {
        var pid = Parent(Environment.ProcessId);
        for (var i = 0; i < 2 && pid > 4 && Shells.Contains(ImageName(pid)); i++) pid = Parent(pid);
        return pid > 4 ? pid : 0;
    }

    /// <summary>程序的建立時間（微秒）；程序不在、打不開或不在同一個登入工作階段（服務、其他使用者，Fable F-02）時是 null</summary>
    public static long? Start(int pid)
    {
        if (pid <= 4 || !ProcessIdToSessionId((uint)pid, out var session) || session != CurrentSession) return null;
        using var handle = Open(pid);
        if (handle is null || !GetProcessTimes(handle, out var created, out _, out _, out _)) return null;
        return created / 10;
    }

    /// <summary>
    /// pid 底下所有子孫程序；pid 不在、不是這個登入工作階段的、或建立時間不是 start（PID 被重用）時回傳 null。
    /// 子程序的建立時間早於父程序的不算（Windows 的父 PID 不會更新：父程序結束後 PID 給了別的程序）
    /// </summary>
    public static HashSet<AgentProcess>? Descendants(int pid, long? start = null)
    {
        if (Start(pid) is not { } rootStart || (start is { } expected && expected != rootStart)) return null;
        var children = new Dictionary<int, List<int>>();
        foreach (var (child, parent) in Snapshot())
        {
            if (child == parent) continue;
            if (!children.TryGetValue(parent, out var list)) children[parent] = list = [];
            list.Add(child);
        }
        var found = new HashSet<AgentProcess>();
        var level = new List<(int Pid, long Start)> { (pid, rootStart) };
        for (var depth = 0; depth < MaxDepth && level.Count > 0; depth++)
        {
            var next = new List<(int, long)>();
            foreach (var (parent, parentStart) in level)
            {
                if (!children.TryGetValue(parent, out var list)) continue;
                foreach (var child in list)
                {
                    if (found.Count >= AgentSessions.MaxProcesses) break;
                    if (Start(child) is not { } begun || begun < parentStart) continue;
                    if (found.Add(new AgentProcess(child, begun))) next.Add((child, begun));
                }
            }
            level = next;
        }
        return found;
    }

    /// <summary>
    /// 點工作階段跳回去（ADR-0017 第 10 節）：所有程序的父 PID 與執行檔名稱（PROCESSENTRY32W 只有檔名，沒有路徑）。只在點擊時列一次
    /// </summary>
    public static Dictionary<int, (int Parent, string Name)> Names()
    {
        var result = new Dictionary<int, (int, string)>();
        foreach (var (pid, parent, name) in Entries()) result[pid] = (parent, name);
        return result;
    }

    /// <summary>所有程序的（PID、父 PID）</summary>
    private static List<(int Pid, int Parent)> Snapshot() => [.. Entries().Select(e => (e.Pid, e.Parent))];

    private static List<(int Pid, int Parent, string Name)> Entries()
    {
        var result = new List<(int, int, string)>();
        var snapshot = CreateToolhelp32Snapshot(SnapProcess, 0);
        if (snapshot == InvalidHandle) return result;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (var ok = Process32FirstW(snapshot, ref entry); ok; ok = Process32NextW(snapshot, ref entry))
                result.Add(((int)entry.ProcessId, (int)entry.ParentProcessId, entry.ExeFile));
        }
        finally
        {
            CloseHandle(snapshot);
        }
        return result;
    }

    /// <summary>父 PID（NtQueryInformationProcess，只拿這一個程序的資訊，Fable F-03）；拿不到是 0</summary>
    private static int Parent(int pid)
    {
        using var handle = Open(pid);
        if (handle is null) return 0;
        var info = new BasicInformation();
        return NtQueryInformationProcess(handle, 0, ref info, Marshal.SizeOf<BasicInformation>(), out _) == 0
            ? (int)info.InheritedFromUniqueProcessId
            : 0;
    }

    /// <summary>執行檔名稱（只留檔名，完整路徑不保留）；拿不到是空字串</summary>
    public static string ImageName(int pid)
    {
        using var handle = Open(pid);
        if (handle is null) return "";
        var buffer = new char[1024];
        var size = (uint)buffer.Length;
        return QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? Path.GetFileName(new string(buffer, 0, (int)size)) : "";
    }

    private static uint CurrentSession => ProcessIdToSessionId((uint)Environment.ProcessId, out var s) ? s : uint.MaxValue;

    private static SafeProcess? Open(int pid)
    {
        var handle = OpenProcess(QueryLimitedInformation, false, (uint)pid);
        if (!handle.IsInvalid) return handle;
        handle.Dispose();
        return null;
    }

    private const uint QueryLimitedInformation = 0x1000;
    private const uint SnapProcess = 0x2;
    private static readonly IntPtr InvalidHandle = new(-1);

    private sealed class SafeProcess() : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid(true)
    {
        protected override bool ReleaseHandle() => CloseHandle(handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcess OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(SafeProcess process, out long creation, out long exit, out long kernel, out long user);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(SafeProcess process, uint flags, [Out] char[] name, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ProcessIdToSessionId(uint pid, out uint session);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(SafeProcess process, int infoClass, ref BasicInformation info, int size, out int returned);
}
