namespace AIUsageMonitor.Core;

/// <summary>
/// 點工作階段跳回那個 session（ADR-0017 第 10 節，同 UsageKit 的 AgentJump）：從 AI 程序沿父程序往上找有視窗的宿主程式。
/// 只用 PID、父 PID、開始時間、執行檔名稱與「有沒有可見的視窗」；不讀命令列、環境變數、工作目錄、視窗標題或任何內容。
/// 程序樹由呼叫端注入（App 包 Toolhelp32 與 EnumWindows，測試用字典），Swift 與 C# 跑同一份 fixtures/agent-jump/cases.json
/// </summary>
public static class AgentJump
{
    /// <summary>往上最多幾層（同背景偵測往下的層數）</summary>
    public const int MaxDepth = 16;

    /// <summary>程序圖上的一個程序：開始時間是微秒，只在同一台電腦上比較；Name 是執行檔名稱（只有檔名）</summary>
    public sealed record Process(int Pid, int Parent, long Start, string Name, bool HasWindow);

    /// <summary>
    /// 從 AI 程序往上，第一個「執行檔名稱在清單裡、而且有可見頂層視窗」的程序（shell、OpenConsole 沒有自己的視窗，會繼續往上到
    /// Windows Terminal；傳統主控台的視窗由系統算在 shell 上，Fable H-04）。start 是收到事件時記下的開始時間（PID 被重用時不一樣，
    /// 當成找不到）；不知道時 null。每一層要求「父的開始時間 ≤ 子的」（Windows 的父 PID 不會更新，父程序結束後可能被重用）
    /// </summary>
    public static int? WindowsTarget(int ai, long? start, AgentHosts hosts, Func<int, Process?> process)
    {
        if (ai <= 4 || process(ai) is not { } current || (start is { } expected && expected != current.Start)) return null;
        for (var depth = 0; depth < MaxDepth; depth++)
        {
            if (current.HasWindow && hosts.Ais(current.Name).Count > 0) return current.Pid;
            if (current.Parent <= 4 || process(current.Parent) is not { } parent || parent.Start > current.Start) return null;
            current = parent;
        }
        return null;
    }
}
