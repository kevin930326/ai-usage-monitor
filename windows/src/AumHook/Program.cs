using System;
using System.IO;
using System.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Hook;

/// <summary>
/// <c>aum-hook.exe &lt;claude|codex&gt;</c>，事件 JSON 從標準輸入傳入（ADR-0019 第 1 節）。
/// 只挑事件、種類、加鹽雜湊後的工作階段 ID、時間與 AI 程序的 PID 寫成 inbox 的一個小檔，再叫醒 App；資料夾名稱與其餘欄位一律不寫。
/// 標準輸出與標準錯誤不印任何東西；任何錯誤都以 0 結束、不擋 AI；App 沒在跑時立刻結束；不連網路。
/// </summary>
internal static class Program
{
    /// <summary>App 的單一執行個體 Mutex 與叫醒 App 的事件（SystemServices.cs 的 SingleInstance）</summary>
    private const string Prefix = @"Local\io.github.kevin930326.AIUsageMonitor.Windows";

    private static int Main(string[] args)
    {
        try
        {
            Console.SetOut(TextWriter.Null);
            Console.SetError(TextWriter.Null);
            Run(args);
        }
        catch (Exception)
        {
            // 任何錯誤都不擋 AI
        }
        return 0;
    }

    private static void Run(string[] args)
    {
        if (args.Length < 1 || AgentNames.Kind(args[0]) is not { } ai) return;
        // App 沒在跑：Mutex 不存在，立刻結束、不讀輸入也不寫檔（App 當機時 Mutex 立即消失）
        if (!Mutex.TryOpenExisting(Prefix, out var mutex)) return;
        mutex.Dispose();
        if (ReadInput() is not { } input) return;
        if (!AgentInbox.Write(Home(), ai, input, DateTimeOffset.UtcNow, AgentProcessTree.AiProcess())) return;
        if (EventWaitHandle.TryOpenExisting(Prefix + ".agent", out var wake))
        {
            using (wake) wake.Set();
        }
    }

    /// <summary>標準輸入最多 1 MB 多一個位元組（超過就整個丟掉）；以位元組讀，中文路徑不受代碼頁影響</summary>
    private static byte[]? ReadInput()
    {
        if (!Console.IsInputRedirected) return null;
        using var stdin = Console.OpenStandardInput();
        using var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        int n;
        while (buffer.Length <= AgentHookInput.MaxInput && (n = stdin.Read(chunk, 0, chunk.Length)) > 0) buffer.Write(chunk, 0, n);
        return buffer.Length <= AgentHookInput.MaxInput ? buffer.ToArray() : null;
    }

    /// <summary>資料夾和 App 相同：AI_USAGE_MONITOR_HOME 優先，否則 %LOCALAPPDATA%\AIUsageMonitor</summary>
    private static string Home()
    {
        var custom = Environment.GetEnvironmentVariable("AI_USAGE_MONITOR_HOME");
        return string.IsNullOrEmpty(custom)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIUsageMonitor")
            : custom;
    }
}
