using System;
using System.Collections.Generic;
using System.IO;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 設定裡的「連接 Claude Code／Codex」（ADR-0019 第 1 節，Mac 的 AgentHookInstaller）：決定設定檔的位置、呼叫 <see cref="AgentHookFiles"/>，
/// 把結果給畫面。隔離模式（測試、截圖、效能量測）的設定檔一律在資料夾裡的假使用者資料夾，不碰真的 .claude、.codex。
/// </summary>
internal sealed class AgentHookInstaller
{
    public enum State { NotInstalled, Installed, NeedsRepair, Unreadable }

    public sealed record Item(State State, AgentHookStatus? Status, string File, string? Message);

    private readonly Dictionary<AgentKind, string> messages = [];

    /// <summary>hook 程式：和 App 同一個資料夾</summary>
    public static string Exe => Path.Combine(AppContext.BaseDirectory, AgentHookConfig.Marker);

    /// <summary>App 的位置能不能放進設定（路徑有 " % ^ &amp; 等字元時不能）</summary>
    public static bool UsablePath => AgentHookConfig.IsUsablePath(Exe);

    private static string UserHome => AppMode.Isolated
        ? DataPaths.Home
        : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static string Directory(AgentKind ai)
    {
        if (AppMode.Isolated) return Path.Combine(DataPaths.Home, ai == AgentKind.Claude ? ".claude" : ".codex");
        byte[]? config = null;
        try { config = System.IO.File.ReadAllBytes(Path.Combine(DataPaths.Home, "config.json")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return AgentHookFiles.ConfigDirectory(ai, config, Environment.GetEnvironmentVariable, UserHome);
    }

    public static string File(AgentKind ai) => AgentHookFiles.ConfigFile(ai, Directory(ai));

    /// <summary>畫面上的路徑：使用者資料夾寫成 %USERPROFILE%（截圖不露出使用者名稱）</summary>
    public static string DisplayPath(AgentKind ai)
    {
        var file = File(ai);
        var home = UserHome.TrimEnd('\\', '/');
        return file.StartsWith(home + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            ? "%USERPROFILE%" + file[home.Length..]
            : file;
    }

    public Item Current(AgentKind ai)
    {
        var file = File(ai);
        messages.TryGetValue(ai, out var message);
        try
        {
            var status = AgentHookFiles.Status(file, ai, Exe, System.IO.File.Exists(Exe));
            var state = !status.Present ? State.NotInstalled : status.NeedsRepair ? State.NeedsRepair : State.Installed;
            return new Item(state, status, file, message);
        }
        catch (Exception e) when (e is AgentHookConfigException or IOException or UnauthorizedAccessException)
        {
            return new Item(State.Unreadable, null, file, message);
        }
    }

    public bool CodexDisabled
    {
        get
        {
            try { return AgentHookFiles.CodexHooksDisabled(System.IO.File.ReadAllBytes(Path.Combine(Directory(AgentKind.Codex), "config.toml"))); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        }
    }

    public void Connect(AgentKind ai)
    {
        if (!System.IO.File.Exists(Exe))
        {
            messages[ai] = "App 的資料夾裡找不到 aum-hook.exe，請重新安裝 App。";
            return;
        }
        try
        {
            var result = AgentHookFiles.Connect(File(ai), ai, Exe, DateTime.Now);
            messages[ai] = !result.Written ? "已經連接好了，不用改。"
                : result.Backup is { } backup ? $"已連接。原本的檔案備份成 {Path.GetFileName(backup)}（在設定檔的資料夾）。"
                : "已連接（新建了這個檔案）。";
        }
        catch (Exception e) when (e is AgentHookConfigException or IOException or UnauthorizedAccessException)
        {
            messages[ai] = Failure(e);
            AppLog.Write($"agent hook connect failed ({AgentNames.Name(ai)}): {e.GetType().Name}");
        }
    }

    public void Disconnect(AgentKind ai)
    {
        try
        {
            var result = AgentHookFiles.Disconnect(File(ai), DateTime.Now);
            messages[ai] = result.Backup is { } backup ? $"已移除。原本的檔案備份成 {Path.GetFileName(backup)}。" : "沒有我們的 hook，不用改。";
        }
        catch (Exception e) when (e is AgentHookConfigException or IOException or UnauthorizedAccessException)
        {
            messages[ai] = Failure(e);
            AppLog.Write($"agent hook disconnect failed ({AgentNames.Name(ai)}): {e.GetType().Name}");
        }
    }

    // 例外的訊息是我們自己寫的中文（不含檔案內容）；其他的不顯示細節
    private static string Failure(Exception e) => e is AgentHookConfigException ? $"{e.Message}，沒有修改。" : "無法寫入設定檔，沒有修改。";
}
