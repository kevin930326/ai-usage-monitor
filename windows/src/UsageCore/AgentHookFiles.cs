using System.Globalization;
using System.Security.AccessControl;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

/// <summary>
/// 連接與移除 hook 時的檔案操作（ADR-0017 第 3 節，同 UsageKit 的 AgentHookFiles.swift）：路徑由呼叫端決定（測試用暫存資料夾），
/// 這裡只負責讀、備份、寫。內容的合併規則在 <see cref="AgentHookConfig"/>。
/// </summary>
public static class AgentHookFiles
{
    /// <summary>每個設定檔最多留幾份我們的備份（設定檔可能有金鑰，副本不無限累積）</summary>
    public const int KeepBackups = 3;
    /// <summary>替換前發現檔案變了時，重新讀取、合併幾次</summary>
    private const int Attempts = 3;

    /// <summary>寫好了（<paramref name="Backup"/> 是改之前的備份，原本沒有檔案時是 null）；或不用改（<paramref name="Written"/> 是 false）</summary>
    public sealed record Result(bool Written, string? Backup)
    {
        public static readonly Result Unchanged = new(false, null);
    }

    /// <summary>
    /// 設定檔的位置：照收集器的規則（token_stats.log_dirs）——<c>config.json</c> 的 <c>claude_config_dir</c>／<c>codex_home</c>，
    /// 其次環境變數 <c>CLAUDE_CONFIG_DIR</c>／<c>CODEX_HOME</c>，其次使用者資料夾的 <c>.claude</c>／<c>.codex</c>。
    /// </summary>
    public static string ConfigDirectory(AgentKind ai, byte[]? collectorConfig, Func<string, string?> environment, string userHome)
    {
        var (key, env, fallback) = ai == AgentKind.Claude
            ? ("claude_config_dir", "CLAUDE_CONFIG_DIR", ".claude")
            : ("codex_home", "CODEX_HOME", ".codex");
        if (ConfigValue(collectorConfig, key) is { Length: > 0 } configured) return ExpandHome(configured, userHome);
        if (environment(env) is { Length: > 0 } fromEnv) return ExpandHome(fromEnv, userHome);
        return Path.Combine(userHome, fallback);
    }

    /// <summary>各 AI 的設定檔名：Claude Code 是 settings.json，Codex 是 hooks.json</summary>
    public static string ConfigFile(AgentKind ai, string directory) =>
        Path.Combine(directory, ai == AgentKind.Claude ? "settings.json" : "hooks.json");

    /// <summary>連接或修好：合併我們的 hook，寫入前先備份</summary>
    public static Result Connect(string file, AgentKind ai, string exe, DateTime now, Action? beforeReplace = null) =>
        Update(file, now, beforeReplace, old =>
        {
            var next = AgentHookConfig.Install(old, ai, exe);
            return old is not null && next.AsSpan().SequenceEqual(old) ? null : next;
        });

    /// <summary>移除：只刪我們的 hook，寫入前先備份</summary>
    public static Result Disconnect(string file, DateTime now) => Update(file, now, null, AgentHookConfig.Uninstall);

    /// <summary>目前的狀態；<paramref name="exe"/> 不在（App 資料夾少了 hook 程式）時，已連接的也算需要修好</summary>
    public static AgentHookStatus Status(string file, AgentKind ai, string exe, bool exeExists)
    {
        var status = AgentHookConfig.Status(Read(file), ai, exe);
        return status.Present && !exeExists ? status with { WrongPath = true } : status;
    }

    /// <summary>
    /// Codex 的 <c>config.toml</c> 有沒有把 hook 關掉（<c>[features]</c> 底下 <c>hooks = false</c>，舊名 <c>codex_hooks</c>）。
    /// 只逐行看這兩個鍵，其他內容不保留。
    /// </summary>
    public static bool CodexHooksDisabled(byte[]? configToml)
    {
        if (configToml is null) return false;
        string text;
        try { text = new System.Text.UTF8Encoding(false, true).GetString(configToml); }
        catch (ArgumentException) { return false; }
        var inFeatures = false;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Split('#', 2)[0].Trim(' ', '\t', '\r');
            if (line.StartsWith('['))
            {
                inFeatures = line == "[features]";
                continue;
            }
            var parts = line.Split('=', 2);
            if (parts.Length != 2) continue;
            var name = parts[0].Trim(' ', '\t');
            var key = inFeatures ? name : name.StartsWith("features.", StringComparison.Ordinal) ? name[9..] : "";
            if (key is "hooks" or "codex_hooks" && parts[1].Trim(' ', '\t') == "false") return true;
        }
        return false;
    }

    /// <summary>備份的檔名：<c>&lt;檔名&gt;.aum-backup-&lt;年月日-時分秒&gt;</c>（本機時間）</summary>
    public static string BackupPath(string file, DateTime now) =>
        file + ".aum-backup-" + now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    // ---------- 內部 ----------

    /// <summary>
    /// 讀、合併、寫；替換前再讀一次，和合併時讀到的不同（別的程式剛改過）就從頭再合併，不覆蓋別人的變更。
    /// 仍有很短的空檔（沒有跨程式的檔案鎖），但不會拿舊內容蓋掉讀了之後才寫入的設定
    /// </summary>
    private static Result Update(string file, DateTime now, Action? beforeReplace, Func<byte[]?, byte[]?> merge)
    {
        file = Resolved(file);
        for (var i = 0; i < Attempts; i++)
        {
            var old = Read(file);
            if (merge(old) is not { } next) return Result.Unchanged;
            beforeReplace?.Invoke();
            var again = Read(file);
            if (!Same(again, old)) continue;
            return new Result(true, Write(next, file, old, now));
        }
        throw new AgentHookConfigException("設定檔正在被其他程式修改，稍後再試");
    }

    private static bool Same(byte[]? a, byte[]? b) => a is null ? b is null : b is not null && a.AsSpan().SequenceEqual(b);

    /// <summary>設定檔是符號連結（dotfiles 管理）時改寫連結指向的檔案；備份放在真正的檔案旁邊</summary>
    private static string Resolved(string file)
    {
        try
        {
            return File.ResolveLinkTarget(file, returnFinalTarget: true)?.FullName ?? file;
        }
        catch (IOException) { return file; }
    }

    private static byte[]? Read(string file)
    {
        try { return File.ReadAllBytes(file); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    /// <summary>
    /// 先備份原檔（同一秒內第二次就加序號，不覆蓋舊備份），再寫暫存檔、以取代的方式換上（同一個資料夾，原子）。
    /// 設定檔可能有金鑰：備份與暫存檔先建立成空檔、套上原檔的權限（Windows 的 DACL；其他系統的檔案模式），之後才寫入內容，
    /// 換上的檔案因此和原檔一樣，不會繼承資料夾較寬鬆的權限（Codex C-01）
    /// </summary>
    private static string? Write(byte[] data, string file, byte[]? old, DateTime now)
    {
        var folder = Path.GetDirectoryName(file)!;
        Directory.CreateDirectory(folder);
        string? backup = null;
        if (old is not null)
        {
            var candidate = BackupPath(file, now);
            for (var n = 2; File.Exists(candidate); n++) candidate = BackupPath(file, now) + "-" + n.ToString(CultureInfo.InvariantCulture);
            // CreateNew：同時有另一個寫入時不覆蓋對方的備份
            WriteWithPermissionsOf(file, candidate, old);
            backup = candidate;
            PruneBackups(file);
        }
        var temp = Path.Combine(folder, "." + Path.GetFileName(file) + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp");
        try
        {
            WriteWithPermissionsOf(old is null ? null : file, temp, data);
            File.Move(temp, file, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { }
            throw;
        }
        return backup;
    }

    /// <summary>
    /// 以 CreateNew 建立 <paramref name="target"/>，權限和 <paramref name="source"/> 相同後才寫入內容（沒有原檔時用預設權限）。
    /// Windows 在建立檔案的同時就套上原檔的 DACL（沒有任何時刻是較寬鬆的權限）
    /// </summary>
    private static void WriteWithPermissionsOf(string? source, string target, byte[] data)
    {
        if (source is not null && OperatingSystem.IsWindows())
        {
            var original = new FileInfo(source).GetAccessControl(AccessControlSections.Access);
            var copy = new FileSecurity();
            copy.SetSecurityDescriptorSddlForm(original.GetSecurityDescriptorSddlForm(AccessControlSections.Access), AccessControlSections.Access);
            using var created = new FileInfo(target).Create(FileMode.CreateNew, FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, copy);
            created.Write(data);
            return;
        }
        using var stream = new FileStream(target, FileMode.CreateNew, FileAccess.Write);
        if (source is not null && !OperatingSystem.IsWindows()) File.SetUnixFileMode(target, File.GetUnixFileMode(source));
        stream.Write(data);
    }

    /// <summary>只刪我們命名樣式的備份，留最新的幾份（時間可以照字串排序；同一秒的序號排在後面）</summary>
    private static void PruneBackups(string file)
    {
        var folder = Path.GetDirectoryName(file)!;
        var prefix = Path.GetFileName(file) + ".aum-backup-";
        try
        {
            var ours = Directory.GetFiles(folder, prefix + "*")
                .Select(Path.GetFileName).OfType<string>()
                .Where(n => n.StartsWith(prefix, StringComparison.Ordinal))
                .OrderBy(n => n.Substring(prefix.Length, Math.Min(15, n.Length - prefix.Length)), StringComparer.Ordinal)
                .ThenBy(n => n.Length > prefix.Length + 16 && int.TryParse(n[(prefix.Length + 16)..], CultureInfo.InvariantCulture, out var k) ? k : 1)
                .ToList();
            foreach (var name in ours.SkipLast(KeepBackups))
            {
                try { File.Delete(Path.Combine(folder, name)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static string? ConfigValue(byte[]? config, string key)
    {
        if (config is null) return null;
        try
        {
            return JsonNode.Parse(config) is JsonObject o && o[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
        }
        catch (Exception e) when (e is JsonException or ArgumentException) { return null; }
    }

    private static string ExpandHome(string path, string userHome) =>
        path == "~" ? userHome
        : path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith(@"~\", StringComparison.Ordinal) ? Path.Combine(userHome, path[2..])
        : path;
}
