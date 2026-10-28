using System.Globalization;
using System.Text.Json;

namespace AIUsageMonitor.Core;

/// <summary>
/// 收集器輸出的快照（docs/02-architecture.md 第 3 節），對應 UsageKit 的 <c>UsageSnapshot</c>。
/// 解析規則與 Swift 的 <c>UsageDecoder</c> 相同：先檢查 <c>schema_version</c>，必要欄位缺少或型別不對時整份視為格式錯誤；
/// 選填的附加資訊（<c>local_status</c>、<c>reset_credits</c>、<c>incidents</c>）格式不對時當成沒有。
/// </summary>
public sealed record UsageSnapshot(int SchemaVersion, DateTimeOffset UpdatedAt, IReadOnlyDictionary<string, ProviderUsage> Providers,
                                   LocalStatus? LocalStatus = null)
{
    /// <summary>App 能解析的 schema 版本（FR-13）</summary>
    public static readonly IReadOnlySet<int> SupportedSchemaVersions = new HashSet<int> { 1 };

    /// <summary>超過門檻沒更新就視為過期（FR-11）：30 分鐘，同 Mac 與 iPhone。</summary>
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(30);

    /// <summary>固定順序：已知服務在前，其他依名稱排序（<c>orderedProviderKeys</c>）。</summary>
    public static readonly IReadOnlyList<string> KnownProviderOrder = ["claude", "codex"];

    public IReadOnlyList<string> OrderedProviderKeys =>
        Providers.Keys
            .OrderBy(k => KnownProviderOrder.Contains(k) ? KnownProviderOrder.ToList().IndexOf(k) : int.MaxValue)
            .ThenBy(k => k, StringComparer.Ordinal)
            .ToList();

    /// <summary>資料時間與現在相差超過門檻（含資料時間在未來）就是過期（<c>isStale(now:after:)</c>）。</summary>
    public bool IsStale(DateTimeOffset now) => Math.Abs((now - UpdatedAt).TotalSeconds) > StaleAfter.TotalSeconds;

    /// <summary>收集器沒有啟用任何服務（<c>hasNoProviders</c>）。</summary>
    public bool HasNoProviders => Providers.Count == 0;

    /// <summary>
    /// 所有服務的可見額度中剩餘最少的一項（FR-15、FR-26）：排除 hidden 與有錯誤的服務；已重置視為剩 100%；
    /// 同分時取較早重置的（沒有重置時間的排最後）。
    /// </summary>
    public ProviderWindow? TightestWindow(DateTimeOffset now)
    {
        ProviderWindow? best = null;
        foreach (var key in OrderedProviderKeys)
        {
            var provider = Providers[key];
            if (provider.Error is not null) continue;
            foreach (var window in provider.VisibleWindows)
            {
                var candidate = new ProviderWindow(key, window);
                if (best is null || IsTighter(candidate, best, now)) best = candidate;
            }
        }
        return best;
    }

    // Swift 的 min(by:) 只在嚴格小於時換掉目前的值：同分且同樣的重置時間時保留先出現的
    private static bool IsTighter(ProviderWindow a, ProviderWindow b, DateTimeOffset now)
    {
        var ra = a.Window.EffectiveRemainingPct(now);
        var rb = b.Window.EffectiveRemainingPct(now);
        if (ra != rb) return ra < rb;
        return (a.Window.ResetsAt ?? DateTimeOffset.MaxValue) < (b.Window.ResetsAt ?? DateTimeOffset.MaxValue);
    }

    /// <summary>依選擇取額度；指定的額度不存在、被隱藏或服務有錯誤時退回剩餘最少的額度（<c>window(for:at:)</c>）。</summary>
    public ProviderWindow? Window(WindowChoice choice, DateTimeOffset now)
    {
        if (choice.Provider is { } provider && choice.WindowId is { } id
            && Providers.TryGetValue(provider, out var usage) && usage.Error is null
            && usage.VisibleWindows.FirstOrDefault(w => w.Id == id) is { } window)
        {
            return new ProviderWindow(provider, window);
        }
        return TightestWindow(now);
    }
}

/// <summary>收集器的本機狀態（只在本機 usage.json，ADR-0014）。個別欄位格式不對時當成沒有。</summary>
public sealed record LocalStatus(string? HistoryPaused, int? DiskFreeMB, DateTimeOffset? HistoryResetAt, string? HistoryKeptAs)
{
    public bool LowDisk => HistoryPaused == "low_disk";
}

public sealed record ProviderUsage(string? Plan, string? Error, IReadOnlyList<UsageWindow> Windows,
                                   IReadOnlyList<ServiceIncident>? Incidents = null)
{
    /// <summary>預設顯示的額度（排除各模型等次要額度，FR-14）</summary>
    public IReadOnlyList<UsageWindow> VisibleWindows => Windows.Where(w => !w.Hidden).ToList();
}

/// <summary>
/// usage.json 裡的進行中事故（ADR-0018 第 4 節），對應 UsageKit 的 <c>ServiceIncident</c>：只有名稱、等級、事故頁與開始時間。
/// </summary>
public sealed record ServiceIncident(string Name, string Impact, string? Url = null, DateTimeOffset? StartedAt = null)
{
    /// <summary>只接受兩個官方狀態頁的事故頁，其他網址不顯示成連結</summary>
    public static readonly IReadOnlySet<string> AllowedHosts = new HashSet<string> { "status.claude.com", "status.openai.com" };

    public Uri? Link => LinkOf(Url);

    public static Uri? LinkOf(string? text) =>
        text is not null && Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
        && AllowedHosts.Contains(uri.Host) && uri.IsDefaultPort && uri.UserInfo.Length == 0
        && uri.AbsolutePath.StartsWith("/incidents/", StringComparison.Ordinal)
        // Uri 會把大寫主機轉成小寫；原文也要是小寫，同 Swift 的 URL.host
        && text.StartsWith($"https://{uri.Host}/", StringComparison.Ordinal) ? uri : null;
}

/// <summary>某個服務的某個額度（<c>ProviderWindow</c>）。</summary>
public sealed record ProviderWindow(string Provider, UsageWindow Window)
{
    /// <summary>「服務/額度 id」，同一份快照中唯一</summary>
    public string Key => $"{Provider}/{Window.Id}";

    /// <summary>畫面上代表這一項的名稱：「Claude 每週」。</summary>
    public string DisplayName => $"{ProviderInfo.DisplayName(Provider)} {Window.Label}";

    /// <summary>螢幕閱讀程式用的完整說法：「剩餘最少的額度：Claude 每週，剩 67%」。</summary>
    public string LeastRemainingAccessibilityLabel(DateTimeOffset now) =>
        $"剩餘最少的額度：{DisplayName}，剩 {SwiftMath.Round(Window.EffectiveRemainingPct(now)).ToString(CultureInfo.InvariantCulture)}%";
}

public static class ProviderInfo
{
    public const string NoProvidersTitle = "沒有啟用任何服務";
    public const string NoProvidersHint = "在這台電腦或 Mac 登入 Claude Code 或 Codex CLI 後，重新執行收集器的安裝腳本（-WithQuota）。";

    public static string DisplayName(string key) => key switch
    {
        "claude" => "Claude",
        "codex" => "Codex",
        "" => "",
        _ => char.ToUpperInvariant(key[0]) + key[1..],
    };
}

public sealed class UsageDecodingException(string message) : Exception(message)
{
    public static UsageDecodingException Malformed() => new("資料格式錯誤");
    public static UsageDecodingException Unsupported(int version) => new($"資料格式版本 {version} 不受支援，請更新 App");
}

public static class UsageDecoder
{
    public static UsageSnapshot Decode(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch (JsonException) { throw UsageDecodingException.Malformed(); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("schema_version", out var v)
                || v.ValueKind != JsonValueKind.Number || !v.TryGetInt32(out var version))
            {
                throw UsageDecodingException.Malformed();
            }
            if (!UsageSnapshot.SupportedSchemaVersions.Contains(version)) throw UsageDecodingException.Unsupported(version);
            try
            {
                var updatedAt = RequiredDate(root, "updated_at");
                var providers = new Dictionary<string, ProviderUsage>();
                foreach (var p in Required(root, "providers", JsonValueKind.Object).EnumerateObject())
                {
                    providers[p.Name] = DecodeProvider(p.Value);
                }
                LocalStatus? local = null;
                if (root.TryGetProperty("local_status", out var ls) && ls.ValueKind == JsonValueKind.Object)
                {
                    local = new LocalStatus(OptionalString(ls, "history_paused"), OptionalInt(ls, "disk_free_mb"),
                                            OptionalDate(ls, "history_reset_at"), OptionalString(ls, "history_kept_as"));
                }
                return new UsageSnapshot(version, updatedAt, providers, local);
            }
            catch (Exception e) when (e is InvalidOperationException or FormatException or KeyNotFoundException)
            {
                throw UsageDecodingException.Malformed();
            }
        }
    }

    private static ProviderUsage DecodeProvider(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new FormatException();
        var windows = Required(e, "windows", JsonValueKind.Array).EnumerateArray().Select(DecodeWindow).ToList();
        return new ProviderUsage(NullableString(e, "plan"), NullableString(e, "error"), windows, DecodeIncidents(e));
    }

    /// <summary>選填的事故：不是陣列或任何一項格式不對時當成沒有（同 Swift 的 <c>try? decodeIfPresent</c>）</summary>
    private static IReadOnlyList<ServiceIncident>? DecodeIncidents(JsonElement e)
    {
        if (!e.TryGetProperty("incidents", out var list) || list.ValueKind != JsonValueKind.Array) return null;
        var result = new List<ServiceIncident>();
        foreach (var i in list.EnumerateArray())
        {
            if (i.ValueKind != JsonValueKind.Object || !i.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String
                || !i.TryGetProperty("impact", out var impact) || impact.ValueKind != JsonValueKind.String) return null;
            string? url = null;
            if (i.TryGetProperty("url", out var u) && u.ValueKind != JsonValueKind.Null)
            {
                if (u.ValueKind != JsonValueKind.String) return null;
                url = u.GetString();
            }
            DateTimeOffset? started = null;
            if (i.TryGetProperty("started_at", out var st) && st.ValueKind != JsonValueKind.Null)
            {
                if (st.ValueKind != JsonValueKind.String || !TryParseIso(st.GetString()!, out var d)) return null;
                started = d;
            }
            result.Add(new ServiceIncident(name.GetString()!, impact.GetString()!, url, started));
        }
        return result;
    }

    private static UsageWindow DecodeWindow(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new FormatException();
        var id = Required(e, "id", JsonValueKind.String).GetString()!;
        var label = Required(e, "label", JsonValueKind.String).GetString()!;
        var used = Required(e, "used_pct", JsonValueKind.Number).GetDouble();
        DateTimeOffset? resets = null;
        if (e.TryGetProperty("resets_at", out var r) && r.ValueKind != JsonValueKind.Null) resets = ParseDate(r);
        var hidden = false;  // v0.1 的輸出沒有 hidden 欄位
        if (e.TryGetProperty("hidden", out var h) && h.ValueKind != JsonValueKind.Null)
        {
            hidden = h.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => throw new FormatException(),
            };
        }
        return new UsageWindow(id, label, used, resets, hidden);
    }

    private static JsonElement Required(JsonElement e, string name, JsonValueKind kind)
    {
        if (!e.TryGetProperty(name, out var value) || value.ValueKind != kind) throw new FormatException(name);
        return value;
    }

    private static DateTimeOffset RequiredDate(JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var value)) throw new FormatException(name);
        return ParseDate(value);
    }

    /// <summary>必要的鍵可為 null（Swift 的 decodeIfPresent），型別不對時格式錯誤。</summary>
    private static string? NullableString(JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw new FormatException(name);
        return value.GetString();
    }

    private static string? OptionalString(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? OptionalInt(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

    private static DateTimeOffset? OptionalDate(JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var v) || v.ValueKind != JsonValueKind.String) return null;
        return TryParseIso(v.GetString()!, out var d) ? d : null;
    }

    /// <summary>ISO 8601（UTC 或含時差），與收集器的 iso_utc 相同；Swift 的 .iso8601 不接受小數秒，這裡也不接受。</summary>
    internal static DateTimeOffset ParseDate(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.String || !TryParseIso(e.GetString()!, out var date)) throw new FormatException("date");
        return date;
    }

    // 一定要帶時區（Z 或 ±hh:mm），同 Swift 的 .iso8601：沒有時區的時間兩邊都視為格式錯誤
    private static readonly string[] IsoFormats = ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:sszzz"];

    public static bool TryParseIso(string text, out DateTimeOffset date) =>
        DateTimeOffset.TryParseExact(text, IsoFormats, CultureInfo.InvariantCulture,
                                     DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out date);
}
