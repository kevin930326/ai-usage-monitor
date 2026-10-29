namespace AIUsageMonitor.Core;

/// <summary>資料夾列表裡的一項：只有路徑、是不是資料夾、修改時間（檔案系統的屬性）</summary>
public readonly record struct MascotDirectoryEntry(string Path, bool IsDirectory, DateTimeOffset Modified);

/// <summary>
/// 「工作中」偵測能用的檔案系統操作：**只有列出資料夾**。沒有讀檔的方法，偵測就不可能讀到紀錄的內容
/// （ADR-0016 第 7 節：只看修改時間，絕不開啟或讀取檔案內容）。同 UsageKit 的 MascotActivity.swift。
/// </summary>
public interface IMascotDirectoryLister
{
    IReadOnlyList<MascotDirectoryEntry> Entries(string directory);
}

/// <summary>實際的檔案系統：只取名稱、屬性與修改時間，不開檔；隱藏的項目略過（同 Mac 的 skipsHiddenFiles）</summary>
public sealed class MascotFileSystemLister : IMascotDirectoryLister
{
    public IReadOnlyList<MascotDirectoryEntry> Entries(string directory)
    {
        try
        {
            return new DirectoryInfo(directory).EnumerateFileSystemInfos()
                .Where(i => !i.Name.StartsWith('.') && !i.Attributes.HasFlag(FileAttributes.Hidden))
                .Select(i => new MascotDirectoryEntry(i.FullName, i.Attributes.HasFlag(FileAttributes.Directory), i.LastWriteTimeUtc))
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return [];
        }
    }
}

/// <summary>
/// Claude 或 Codex 是否正在跑（ADR-0016 第 5 節）：紀錄檔（.jsonl）最近被改過就算工作中，很久沒改就睡覺。
/// 展開時每 5 秒、收著時每 60 秒看一次；不常駐監看檔案系統。接上 hook（ADR-0017）的 AI 改用 hook 的狀態。
/// </summary>
public sealed class MascotActivityProbe(IReadOnlyList<MascotActivityProbe.Root> roots, IMascotDirectoryLister? lister = null)
{
    /// <summary>一個紀錄資料夾與往下看幾層；NewestByName：每層只看名稱排最後的幾個資料夾（Codex 的年／月／日）</summary>
    public sealed record Root(string Path, int Depth, int? NewestByName = null);

    /// <summary>多久內改過算工作中（秒）</summary>
    public const double ActiveWindowSeconds = 45;
    /// <summary>一次最多列出幾個資料夾</summary>
    public const int MaxListings = 400;

    private readonly IMascotDirectoryLister lister = lister ?? new MascotFileSystemLister();

    public IReadOnlyList<Root> Roots { get; } = roots;

    /// <summary>某個 AI 的紀錄位置（設定資料夾的規則同收集器與 hook 的安裝：config.json → 環境變數 → 使用者資料夾）</summary>
    public static Root DefaultRoot(AgentKind ai, byte[]? collectorConfig, Func<string, string?> environment, string userHome)
    {
        var dir = AgentHookFiles.ConfigDirectory(ai, collectorConfig, environment, userHome);
        return ai == AgentKind.Claude
            ? new Root(System.IO.Path.Combine(dir, "projects"), 2)
            : new Root(System.IO.Path.Combine(dir, "sessions"), 4, 2);
    }

    public bool IsWorking(DateTimeOffset now) => IsActive(ActiveWindowSeconds, now);

    /// <summary>最近 seconds 秒內有沒有紀錄檔被改過</summary>
    public bool IsActive(double seconds, DateTimeOffset now)
    {
        var since = now.AddSeconds(-seconds);
        // 每個服務各有一份預算：Claude 的專案再多，也不會讓 Codex 沒得看
        var share = MaxListings / Math.Max(Roots.Count, 1);
        return Roots.Any(root =>
        {
            var budget = share;
            return Scan(root.Path, root.Depth, root, since, ref budget);
        });
    }

    private bool Scan(string directory, int depth, Root root, DateTimeOffset since, ref int budget)
    {
        if (depth <= 0 || budget <= 0) return false;
        budget -= 1;
        var entries = lister.Entries(directory);
        if (entries.Any(e => !e.IsDirectory && e.Path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) && e.Modified >= since)) return true;
        var folders = entries.Where(e => e.IsDirectory);
        folders = root.NewestByName is { } newest
            ? folders.OrderByDescending(e => System.IO.Path.GetFileName(e.Path), StringComparer.Ordinal).Take(newest)
            // 最近改過的資料夾（新的 session 檔）先看
            : folders.OrderByDescending(e => e.Modified);
        foreach (var folder in folders.ToList())
        {
            if (Scan(folder.Path, depth - 1, root, since, ref budget)) return true;
        }
        return false;
    }
}
