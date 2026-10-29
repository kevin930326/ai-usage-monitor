using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

/// <summary>
/// 跨裝置的 AI 狀態（ADR-0019 第 2 節，同 UsageKit 的 AgentSync.swift）。App 只讀寫本機檔案；連中繼的是收集器的 <c>agent-sync</c>。
/// <list type="bullet">
/// <item><c>agent-state.json</c>：這台電腦的彙總（App 寫、收集器讀後上傳）。每個 AI 一列：最高的狀態、工作階段數、進入這個狀態的時間；
/// 不含資料夾名稱、工作階段 ID 或任何內容。</item>
/// <item><c>agent-remote.json</c>：其他電腦的彙總（收集器下載後寫、App 讀）。收集器已經拿掉自己這台與裝置 ID。</item>
/// </list>
/// </summary>
public static class AgentSummary
{
    public const int Version = 1;
    public const string FileName = "agent-state.json";

    /// <summary>這台電腦的彙總，鍵的順序固定（Swift、C# 輸出相同）。沒有工作階段的 AI 不列</summary>
    public static byte[] Encoded(AgentSessions sessions, long now)
    {
        var ordered = sessions.Ordered(now);
        var rows = new List<string>();
        foreach (var ai in new[] { AgentKind.Claude, AgentKind.Codex })
        {
            var mine = ordered.Where(s => s.Ai == ai).ToList();
            if (mine.Count == 0) continue;
            var top = mine[0];
            var state = top.State(now, sessions.IdleAfter);
            // 同一個狀態有幾個工作階段時取最早進入的：哪一個最近有事件不影響彙總（Fable F-01）
            var since = mine.Where(s => s.State(now, sessions.IdleAfter) == state).Min(s => s.Since);
            // 背景執行中寫成工作中（ADR-0017 第 7 節）：中繼與舊版 App 不用改格式
            var shared = state == AgentState.Background ? AgentState.Working : state;
            rows.Add($"{{\"ai\":\"{AgentNames.Name(ai)}\",\"state\":\"{AgentNames.Name(shared)}\"," +
                     $"\"sessions\":{mine.Count.ToString(CultureInfo.InvariantCulture)},\"since\":{since.ToString(CultureInfo.InvariantCulture)}}}");
        }
        return Encoding.UTF8.GetBytes($"{{\"v\":{Version},\"ais\":[{string.Join(",", rows)}]}}");
    }

    /// <summary>App 結束時寫的「全部閒置」</summary>
    public static byte[] Empty => Encoding.UTF8.GetBytes($"{{\"v\":{Version},\"ais\":[]}}");
}

/// <summary>其他電腦的一個 AI 要顯示的狀態</summary>
public sealed record RemoteAgent(string Device, AgentKind Ai, AgentState State, int Sessions)
{
    /// <summary>進入這個狀態的時間、中繼收到的時間（換算成本機時間，ms；ADR-0019「角色合併所有電腦」，同 Swift）</summary>
    public long? Since { get; init; }
    public long Updated { get; init; }
    /// <summary>清單裡列不列（等你、閒置不列，只給角色算醒著）</summary>
    public bool IsListed { get; init; } = true;

    /// <summary>「桌機：Claude Code 需要你」</summary>
    public string Text => $"{Device}：{AgentText.Name(Ai)} {State switch
    {
        AgentState.NeedsYou => "需要你",
        AgentState.Error => "出錯了",
        AgentState.Working => "工作中",
        AgentState.Background => "背景執行中",
        AgentState.Done => "完成了",
        AgentState.Waiting => "等你",
        _ => "閒置",
    }}";
}

public static class RemoteAgents
{
    public const string FileName = "agent-remote.json";
    /// <summary>中繼收到的時間超過這麼久就不顯示（那台電腦關機或斷線）</summary>
    public const long MaxAge = 30 * 60_000;
    /// <summary>「完成了」「出錯」進入那個狀態超過這麼久，當成「等你」不顯示（ADR-0017 第 9 節，同 AgentSync.swift）</summary>
    public const long FadeAfter = 30 * 60_000;
    private const int MaxDevices = 16;
    private const int MaxName = 32;

    /// <summary>
    /// 讀 <c>agent-remote.json</c>（格式見 AgentSync.swift）。多久以前＝中繼那邊的差（now − updated_at，同一個時鐘）＋下載後在本機經過的時間。
    /// 格式不對整個不顯示；個別欄位不對略過那一列。依狀態（需要你最前）、裝置名稱、AI 排序。
    /// all：等你、閒置也留著（IsListed 為 false），角色合併所有電腦時用
    /// </summary>
    public static List<RemoteAgent> Parse(byte[] data, long localNow, bool all = false)
    {
        var list = new List<RemoteAgent>();
        if (data.Length > 64 * 1024) return list;
        JsonObject root;
        try
        {
            if (JsonNode.Parse(data) is not JsonObject o) return list;
            _ = o.Count;
            root = o;
        }
        catch (Exception e) when (e is JsonException or ArgumentException) { return list; }
        if (Int(root["v"]) != 1 || Int(root["fetched_at"]) is not { } fetched || Int(root["now"]) is not { } now
            || root["devices"] is not JsonArray devices) return list;
        var elapsed = Math.Max(0, localNow - fetched);
        foreach (var device in devices.Take(MaxDevices).OfType<JsonObject>())
        {
            try
            {
                if (device["name"] is not JsonValue nameNode || nameNode.GetValueKind() != JsonValueKind.String
                    || Int(device["updated_at"]) is not { } updated || device["ais"] is not JsonArray ais) continue;
                var name = CleanName(nameNode.GetValue<string>());
                if (name.Length == 0 || now - updated + elapsed > MaxAge || now - updated < -60_000) continue;
                var seen = new HashSet<AgentKind>();
                foreach (var row in ais.Take(2).OfType<JsonObject>())
                {
                    if (AgentNames.Kind(Text(row["ai"])) is not { } ai || seen.Contains(ai)
                        || State(Text(row["state"])) is not { } state || Int(row["sessions"]) is not { } sessions || sessions is < 0 or > 32) continue;
                    seen.Add(ai);
                    var listed = state is AgentState.NeedsYou or AgentState.Error or AgentState.Working or AgentState.Done;
                    if (!listed && !all) continue;
                    var since = Int(row["since"]);
                    // 完成、出錯：從進入的時間算 30 分鐘（中繼的時鐘＋下載後經過的時間）；App 每分鐘重讀一次
                    if (state is AgentState.Done or AgentState.Error && since is { } s && now - s + elapsed >= FadeAfter) continue;
                    // 中繼的時間換成本機：中繼的 now 對到本機的 fetched_at
                    list.Add(new RemoteAgent(name, ai, state, (int)sessions)
                    {
                        Since = since is { } at ? fetched + at - now : null, Updated = fetched + updated - now, IsListed = listed,
                    });
                }
            }
            catch (ArgumentException) { }   // 這台的物件有重複的鍵：略過
        }
        list.Sort((a, b) =>
        {
            if (a.State != b.State) return ((int)b.State).CompareTo((int)a.State);
            var byName = string.CompareOrdinal(a.Device, b.Device);
            return byName != 0 ? byName : string.CompareOrdinal(AgentNames.Name(a.Ai), AgentNames.Name(b.Ai));
        });
        return list;
    }

    private static AgentState? State(string? name) =>
        name is null ? null : Enum.GetValues<AgentState>().Cast<AgentState?>().FirstOrDefault(s => AgentNames.Name(s!.Value) == name);

    /// <summary>控制字元與格式字元拿掉、前後的空白（Zs 與 tab）去掉、最多 32 個 Unicode 純量</summary>
    public static string CleanName(string name)
    {
        var runes = name.EnumerateRunes()
            .Where(r => Rune.GetUnicodeCategory(r) is not (UnicodeCategory.Control or UnicodeCategory.Format))
            .ToList();
        static bool Space(Rune r) => r.Value == '\t' || Rune.GetUnicodeCategory(r) == UnicodeCategory.SpaceSeparator;
        var start = runes.FindIndex(r => !Space(r));
        if (start < 0) return "";
        var end = runes.FindLastIndex(r => !Space(r));
        return string.Concat(runes.Skip(start).Take(end - start + 1).Take(MaxName).Select(r => r.ToString()));
    }

    private static string? Text(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    /// <summary>JSON 的整數（1.0 也算；不收其他小數與布林）</summary>
    private static long? Int(JsonNode? node)
    {
        if (node is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<long>(out var n)) return Math.Abs(n) < 9_000_000_000_000_000 ? n : null;
        var d = v.GetValue<double>();
        return d == Math.Floor(d) && Math.Abs(d) < 9e15 ? (long)d : null;
    }
}
