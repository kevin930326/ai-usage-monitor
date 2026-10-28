namespace AIUsageMonitor.Core;

// 這台電腦的 Token 統計（TokenStats.swift，FR-43、FR-44、FR-60，ADR-0009 第 4 節、ADR-0011 第 4 節）。
// 資料來自收集器寫的 history.sqlite3（daily_tokens、hourly_tokens、records、record_days；讀取在 HistoryReader）；
// 這裡只有純計算。日期是收集器以本機時區寫入的 YYYY-MM-DD；計算以 DateOnly 進行，時區只用來決定「今天」。

/// <summary>全部／Claude／Codex 切換。</summary>
public enum TokenScope { All, Claude, Codex }

public static class TokenScopes
{
    public static readonly IReadOnlyList<TokenScope> AllCases = [TokenScope.All, TokenScope.Claude, TokenScope.Codex];

    public static string RawValue(this TokenScope scope) => scope switch
    {
        TokenScope.Claude => "claude",
        TokenScope.Codex => "codex",
        _ => "all",
    };

    public static string Title(this TokenScope scope) => scope switch
    {
        TokenScope.Claude => "Claude",
        TokenScope.Codex => "Codex",
        _ => "全部",
    };

    public static bool Includes(this TokenScope scope, string provider) => scope == TokenScope.All || provider == scope.RawValue();

    /// <summary>records 的鍵：全部沒有後綴，各服務加 :claude／:codex</summary>
    public static string RecordKey(this TokenScope scope, string baseKey) => scope == TokenScope.All ? baseKey : $"{baseKey}:{scope.RawValue()}";
}

/// <summary>統計的計算方式（FR-60）：主數字（input＋cache_write＋output，預設），或再加上 cache_read。</summary>
public enum TokenMeasure { Main, IncludingCacheRead }

public static class TokenMeasures
{
    /// <summary>數字旁的小字與滑鼠說明</summary>
    public const string Badge = "含快取";
    public const string Help = "包含 AI 重複讀取對話的快取，通常佔總量的大部分";
}

/// <summary>四種 Token 分開保存（ADR-0009 第 4 節）；Reasoning 是 Output 的明細，不另外加總。</summary>
public readonly record struct TokenCounts(long Input = 0, long CacheWrite = 0, long CacheRead = 0, long Output = 0, long Reasoning = 0)
{
    public static readonly TokenCounts Zero = new();

    /// <summary>顯示的「Token」主數字 = input + cache_write + output（不含 cache_read）</summary>
    public long Main => Input + CacheWrite + Output;

    /// <summary>依計算方式的數字：主數字，或再加上 cache_read（FR-60）</summary>
    public long Value(TokenMeasure measure) => measure == TokenMeasure.IncludingCacheRead ? Main + CacheRead : Main;

    public static TokenCounts operator +(TokenCounts a, TokenCounts b) =>
        new(a.Input + b.Input, a.CacheWrite + b.CacheWrite, a.CacheRead + b.CacheRead, a.Output + b.Output, a.Reasoning + b.Reasoning);
}

/// <summary>daily_tokens 的一列。Device 是這台電腦時為空字串（TokenDevices.Local），第二層下載的其他電腦是中繼的 device_id。</summary>
public sealed record TokenDayRow(string Day, string Provider, string Model, TokenCounts Counts, int TaskCount = 0, int TaskSeconds = 0,
                                 int LongestTaskSeconds = 0, string Device = TokenDevices.Local);

/// <summary>hourly_tokens 的一列（只在完整統計視窗讀取）。</summary>
public sealed record TokenHourRow(string Day, int Hour, string Provider, string Model, TokenCounts Counts);

/// <summary>records 的一列：個人紀錄（不隨保留期間刪除）。</summary>
public sealed record TokenRecord(long Value, string? Day = null);

/// <summary>從資料庫讀到的 Token 統計（TokenStatsData）。</summary>
public sealed record TokenStatsData
{
    public IReadOnlyList<TokenDayRow> Days { get; init; } = [];
    public IReadOnlyList<TokenHourRow> Hours { get; init; } = [];
    public IReadOnlyDictionary<string, TokenRecord> Records { get; init; } = new Dictionary<string, TokenRecord>();

    /// <summary>record_days：每天每個服務的主數字，不套用保留期間（目前連續天數用）</summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, long>> RecordDays { get; init; } =
        new Dictionary<string, IReadOnlyDictionary<string, long>>();

    /// <summary>首次掃描完成（meta.first_scan_done）</summary>
    public bool FirstScanDone { get; init; }

    /// <summary>首次掃描進度 0～100（meta.first_scan_progress）；收集器還沒開始時為 null</summary>
    public int? FirstScanProgress { get; init; }

    /// <summary>略過的紀錄行數（無法解析＋過長）；&gt; 0 時顯示「部分紀錄無法解析」</summary>
    public int SkippedLines { get; init; }

    /// <summary>收集器判斷對話紀錄的格式可能已改變（meta.token_format_suspect，ADR-0009 第 9 節）</summary>
    public bool FormatSuspect { get; init; }

    /// <summary>保留期間（天，0＝永久）</summary>
    public int RetentionDays { get; init; } = 365;

    /// <summary>實際還有每日資料的第一天（meta.token_days_from）；沒有記錄時為 null</summary>
    public string? DataFrom { get; init; }

    /// <summary>第二層的裝置清單（沒有安裝第二層時為 TokenDevices.None）</summary>
    public TokenDevices Devices { get; init; } = TokenDevices.None;

    /// <summary>計算方式（Measured 設定）；所有 Token 數字、長條、熱力圖與各模型都依它計算</summary>
    public TokenMeasure Measure { get; private init; } = TokenMeasure.Main;

    public static readonly TokenStatsData Empty = new();

    /// <summary>統計卡片與完整統計視窗的提示</summary>
    public const string FormatSuspectNotice = "紀錄格式可能已改變，統計可能不完整";

    /// <summary>有任何 Token 資料（含已超過保留期間、只剩個人紀錄的）；與計算方式無關</summary>
    public bool HasData => Days.Any(d => d.Counts.Value(TokenMeasure.IncludingCacheRead) > 0) || HasRecord("");

    /// <summary>這個範圍有資料的服務（給切換列決定要不要顯示）</summary>
    public IReadOnlyList<string> Providers =>
        new[] { "claude", "codex" }
            .Where(p => Days.Any(d => d.Provider == p && d.Counts.Value(TokenMeasure.IncludingCacheRead) > 0) || HasRecord($":{p}"))
            .ToList();

    private bool HasRecord(string suffix) =>
        new[] { "total_tokens", "total_tokens_cached" }.Any(k => (Records.TryGetValue(k + suffix, out var r) ? r.Value : 0) > 0);

    /// <summary>
    /// 每日資料最早還保留的那一天：目前保留期間的起點與 DataFrom 較晚的一個；永久保留且沒有刪除過時為 null。
    /// </summary>
    public DateOnly? FirstAvailableDay(DateTimeOffset now, TimeZoneInfo zone)
    {
        DateOnly? byRetention = RetentionDays > 0 ? LocalCalendar.Date(now.AddSeconds(-(double)RetentionDays * 86400), zone) : null;
        var deleted = DataFrom is null ? null : LocalCalendar.ParseKey(DataFrom);
        return (byRetention, deleted) switch
        {
            ({ } a, { } b) => a > b ? a : b,
            var (a, b) => a ?? b,
        };
    }

    /// <summary>改用另一種計算方式。Records 不動。</summary>
    public TokenStatsData Measured(TokenMeasure measure) => this with { Measure = measure };

    /// <summary>
    /// Token 數的個人紀錄（best_day_tokens、total_tokens，含 :服務 後綴）。含快取讀取時讀收集器另外記的 *_cached；
    /// 舊版收集器沒有時為 null，改由已讀取的每日資料計算。
    /// </summary>
    internal TokenRecord? TokenRecordFor(string key)
    {
        if (Measure != TokenMeasure.IncludingCacheRead) return Records.GetValueOrDefault(key);
        var parts = key.Split(':', 2);
        var cached = $"{parts[0]}_cached" + (parts.Length > 1 ? $":{parts[1]}" : "");
        return Records.GetValueOrDefault(cached);
    }

    /// <summary>每天（依範圍）的合計</summary>
    public IReadOnlyDictionary<string, TokenCounts> DailyTotals(TokenScope scope)
    {
        var result = new Dictionary<string, TokenCounts>();
        foreach (var row in Days.Where(r => scope.Includes(r.Provider)))
        {
            result[row.Day] = result.GetValueOrDefault(row.Day) + row.Counts;
        }
        return result;
    }
}

/// <summary>統計的四個數字（TokenSummary）。</summary>
public sealed class TokenSummary
{
    /// <summary>本週（星期一起）的合計</summary>
    public TokenCounts ThisWeek { get; }

    /// <summary>上週同一段期間（星期一到上週的今天）的數字（依計算方式）；超過保留期間時為 0</summary>
    public long LastWeekSamePeriod { get; }

    public TokenRecord? BestDay { get; }
    public TokenRecord? LongestTaskSeconds { get; }

    /// <summary>目前連續使用的天數：今天有用時算到今天，今天還沒用時算到昨天（還沒中斷）</summary>
    public int CurrentStreak { get; }

    public TokenRecord? LongestStreak { get; }
    public TokenRecord? Total { get; }
    public TokenMeasure Measure { get; }

    public long ThisWeekValue => ThisWeek.Value(Measure);

    /// <summary>與上週同期相比的變化（%）；上週同期為 0 時為 null</summary>
    public double? ChangePct => LastWeekSamePeriod > 0
        ? ((double)ThisWeekValue - LastWeekSamePeriod) / LastWeekSamePeriod * 100
        : null;

    /// <summary>目前的連續天數就是（或追平）最長紀錄</summary>
    public bool StreakIsRecord => CurrentStreak > 0 && CurrentStreak >= (LongestStreak?.Value ?? 0);

    public TokenSummary(TokenStatsData data, TokenScope scope, DateTimeOffset now, TimeZoneInfo zone)
    {
        var m = data.Measure;
        Measure = m;
        var totals = data.DailyTotals(scope);
        TokenCounts Day(DateOnly d) => totals.GetValueOrDefault(LocalCalendar.Key(d));
        var today = LocalCalendar.Date(now, zone);
        var monday = LocalCalendar.StartOfWeek(today);
        var daysIntoWeek = today.DayNumber - monday.DayNumber;
        var week = TokenCounts.Zero;
        long last = 0;
        for (var offset = 0; offset <= Math.Max(daysIntoWeek, 0); offset++)
        {
            var day = monday.AddDays(offset);
            week += Day(day);
            last += Day(day.AddDays(-7)).Value(m);
        }
        ThisWeek = week;
        // 上週同期已超過保留期間：無法比較
        var lastWeekStart = monday.AddDays(-7);
        var comparable = data.FirstAvailableDay(now, zone) is not { } first || lastWeekStart >= first;
        LastWeekSamePeriod = comparable ? last : 0;

        // 個人紀錄以 records 為準（不受保留期間影響）；收集器還沒寫入時從每日資料算
        TokenRecord? Record(string key) => data.Records.GetValueOrDefault(scope.RecordKey(key));
        TokenRecord? computedBest = null;
        foreach (var (key, counts) in totals)
        {
            var v = counts.Value(m);
            if (v <= 0) continue;
            // 數字最大，同分取較早的日期
            if (computedBest is null || v > computedBest.Value || (v == computedBest.Value && string.CompareOrdinal(key, computedBest.Day) < 0))
            {
                computedBest = new TokenRecord(v, key);
            }
        }
        BestDay = FirstMax(data.TokenRecordFor(scope.RecordKey("best_day_tokens")), computedBest);
        TokenRecord? computedLongest = null;
        foreach (var row in data.Days.Where(r => scope.Includes(r.Provider) && r.LongestTaskSeconds > 0))
        {
            if (computedLongest is null || row.LongestTaskSeconds > computedLongest.Value) computedLongest = new TokenRecord(row.LongestTaskSeconds, row.Day);
        }
        LongestTaskSeconds = FirstMax(Record("longest_task_seconds"), computedLongest);
        Total = data.TokenRecordFor(scope.RecordKey("total_tokens"))
                ?? (totals.Count == 0 ? null : new TokenRecord(totals.Values.Sum(c => c.Value(m))));

        // 有 record_days 時以它為準（不受保留期間影響），否則用每日資料。一律用主數字：含快取讀取不改變連續天數
        bool Used(DateOnly date)
        {
            var key = LocalCalendar.Key(date);
            var main = totals.GetValueOrDefault(key).Main > 0;
            if (data.RecordDays.Count == 0) return main;
            return (data.RecordDays.TryGetValue(key, out var byProvider) && byProvider.Any(p => scope.Includes(p.Key) && p.Value > 0)) || main;
        }
        var streak = 0;
        var cursor = Used(today) ? today : today.AddDays(-1);
        while (Used(cursor))
        {
            streak += 1;
            cursor = cursor.AddDays(-1);
        }
        CurrentStreak = streak;
        // 最長紀錄以 records 為準（收集器從 record_days 算，涵蓋所有日子），目前這段更長時記成今天。
        // 沒有 records 時（「所有電腦」、其他電腦、舊版收集器）從每日資料找所有連續區段的最大值，
        // 過去較長、已結束的連續也要算到；同樣長取較早結束的，目前這段的結束日記成今天
        if (Record("longest_streak_days") is { } recordStreak)
        {
            LongestStreak = streak > recordStreak.Value ? new TokenRecord(streak, LocalCalendar.Key(today)) : recordStreak;
        }
        else
        {
            var currentLast = LocalCalendar.Key(cursor.AddDays(streak));
            TokenRecord? longest = null;
            var run = 0;
            DateOnly? previous = null;
            foreach (var key in totals.Keys.Union(data.RecordDays.Keys).Order(StringComparer.Ordinal))
            {
                if (LocalCalendar.ParseKey(key) is not { } date || !Used(date)) continue;
                run = previous is { } p && p.AddDays(1) == date ? run + 1 : 1;
                previous = date;
                var end = streak > 0 && run == streak && key == currentLast ? LocalCalendar.Key(today) : key;
                if (run > (longest?.Value ?? 0)) longest = new TokenRecord(run, end);
            }
            LongestStreak = longest;
        }
    }

    /// <summary>Swift 的 [a, b].compactMap { $0 }.max { $0.value &lt; $1.value }：同分時取前一個</summary>
    private static TokenRecord? FirstMax(TokenRecord? a, TokenRecord? b) =>
        a is null ? b : b is null ? a : b.Value > a.Value ? b : a;
}

/// <summary>Token 活動的範圍：30 天、週、累計。</summary>
public enum TokenActivityRange { Days30, Weeks, Cumulative }

/// <summary>長條圖的一根（一天或一週）。</summary>
/// <param name="ByProvider">依服務分開的數字（疊加長條用，依計算方式）</param>
/// <param name="Available">這段期間的每日資料還在保留期間內（否則不畫，也不當成 0）</param>
public sealed record TokenBar(DateOnly Start, IReadOnlyDictionary<string, long> ByProvider, TokenCounts Counts, bool Available = true,
                              TokenMeasure Measure = TokenMeasure.Main)
{
    /// <summary>長條的高度（依計算方式；累計時是當天結束時的累計）</summary>
    public long Value => Counts.Value(Measure);
}

public static class TokenActivity
{
    public const int DayCount = 30;
    public const int WeekCount = 12;

    public static IReadOnlyList<TokenBar> Bars(TokenStatsData data, TokenScope scope, TokenActivityRange range, DateTimeOffset now, TimeZoneInfo zone)
    {
        var m = data.Measure;
        var today = LocalCalendar.Date(now, zone);
        var first = data.FirstAvailableDay(now, zone);
        bool Available(DateOnly date) => first is not { } f || date >= f;
        var byDay = new Dictionary<string, (TokenCounts Counts, Dictionary<string, long> Providers)>();
        foreach (var row in data.Days.Where(r => scope.Includes(r.Provider)))
        {
            if (!byDay.TryGetValue(row.Day, out var entry)) entry = (TokenCounts.Zero, new Dictionary<string, long>());
            entry.Providers[row.Provider] = entry.Providers.GetValueOrDefault(row.Provider) + row.Counts.Value(m);
            byDay[row.Day] = (entry.Counts + row.Counts, entry.Providers);
        }
        (TokenCounts Counts, IReadOnlyDictionary<string, long> Providers) Day(DateOnly date) =>
            byDay.TryGetValue(LocalCalendar.Key(date), out var v) ? (v.Counts, v.Providers) : (TokenCounts.Zero, new Dictionary<string, long>());
        switch (range)
        {
            case TokenActivityRange.Days30:
                return Enumerable.Range(0, DayCount).Select(i =>
                {
                    var date = today.AddDays(i - DayCount + 1);
                    var (counts, providers) = Day(date);
                    return new TokenBar(date, new Dictionary<string, long>(providers), counts, Available(date), m);
                }).ToList();
            case TokenActivityRange.Weeks:
                var monday = LocalCalendar.StartOfWeek(today);
                return Enumerable.Range(0, WeekCount).Select(w =>
                {
                    var start = monday.AddDays(7 * (w - WeekCount + 1));
                    var counts = TokenCounts.Zero;
                    var providers = new Dictionary<string, long>();
                    for (var d = 0; d < 7; d++)
                    {
                        var (c, p) = Day(start.AddDays(d));
                        counts += c;
                        foreach (var (k, v) in p) providers[k] = providers.GetValueOrDefault(k) + v;
                    }
                    // 一週的第一天也在保留期間內才算完整
                    return new TokenBar(start, providers, counts, Available(start), m);
                }).ToList();
            default:
                // 每天結束時的累計：以 records 的累計 Token 往回扣；沒有 records 時是每日資料的合計。累計放在 Input
                var daily = Enumerable.Range(0, DayCount).Select(i => Day(today.AddDays(i - DayCount + 1)).Counts).ToList();
                var windowTotal = daily.Sum(c => c.Value(m));
                var allTotals = data.DailyTotals(scope).Values.Sum(c => c.Value(m));
                var running = Math.Max((data.TokenRecordFor(scope.RecordKey("total_tokens"))?.Value ?? allTotals) - windowTotal, 0);
                return daily.Select((counts, i) =>
                {
                    running += counts.Value(m);
                    var date = today.AddDays(i - DayCount + 1);
                    return new TokenBar(date, new Dictionary<string, long>(), new TokenCounts(Input: running), Available(date));
                }).ToList();
        }
    }
}

/// <summary>活動熱力圖：一欄一週（星期一在上），最右欄是本週；今天以後與保留期間以前的格子為 null。</summary>
public sealed class TokenHeatmap
{
    public int Weeks { get; }
    public DateOnly FirstMonday { get; }

    /// <summary>Weeks × 7，依欄（週）再依列（星期一～日）排列</summary>
    public IReadOnlyList<long?> Cells { get; }

    /// <summary>分成 5 級的門檻（非零值的五分位數）</summary>
    public IReadOnlyList<long> Thresholds { get; }

    /// <summary>有格子在保留期間以前（不畫，與「沒有使用」區分）</summary>
    public bool Truncated { get; }

    public TokenHeatmap(TokenStatsData data, TokenScope scope, DateTimeOffset now, TimeZoneInfo zone, int weeks)
    {
        var m = data.Measure;
        var totals = data.DailyTotals(scope);
        var today = LocalCalendar.Date(now, zone);
        Weeks = weeks;
        FirstMonday = LocalCalendar.StartOfWeek(today).AddDays(-7 * (weeks - 1));
        var first = data.FirstAvailableDay(now, zone);
        var cells = new List<long?>();
        var truncated = false;
        for (var i = 0; i < weeks * 7; i++)
        {
            var date = FirstMonday.AddDays(i);
            if (first is { } f && date < f)
            {
                truncated = true;
                cells.Add(null);
                continue;
            }
            cells.Add(date > today ? null : totals.TryGetValue(LocalCalendar.Key(date), out var c) ? c.Value(m) : 0);
        }
        Cells = cells;
        Truncated = truncated;
        var nonZero = cells.OfType<long>().Where(v => v > 0).Order().ToList();
        Thresholds = nonZero.Count == 0 ? [] : new[] { 0.2, 0.4, 0.6, 0.8 }.Select(p => nonZero[(int)((nonZero.Count - 1) * p)]).ToList();
    }

    /// <summary>0（沒有使用）～5（最多）</summary>
    public int Level(long value) => value <= 0 ? 0 : 1 + Thresholds.Count(t => value > t);

    public DateOnly Date(int column, int row) => FirstMonday.AddDays(column * 7 + row);
}

/// <summary>一個服務的一個模型的合計（「各模型」的一列）</summary>
public sealed record TokenModelTotal(string Provider, string Model, TokenCounts Counts)
{
    public string Id => $"{Provider}/{Model}";
}

public static class TokenBreakdown
{
    /// <summary>各模型的合計，依數字（計算方式）由大到小，同分依模型、服務名稱。以（服務、模型）分組</summary>
    public static IReadOnlyList<TokenModelTotal> Models(TokenStatsData data, TokenScope scope)
    {
        var m = data.Measure;
        var result = new Dictionary<string, TokenModelTotal>();
        foreach (var row in data.Days.Where(r => scope.Includes(r.Provider)))
        {
            var key = $"{row.Provider}/{row.Model}";
            var current = result.GetValueOrDefault(key) ?? new TokenModelTotal(row.Provider, row.Model, TokenCounts.Zero);
            result[key] = current with { Counts = current.Counts + row.Counts };
        }
        return result.Values.Where(t => t.Counts.Value(m) > 0)
            .OrderByDescending(t => t.Counts.Value(m))
            .ThenBy(t => t.Model, StringComparer.Ordinal)
            .ThenBy(t => t.Provider, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>一天中各時段（0～23 時）的合計（依計算方式）</summary>
    public static IReadOnlyList<long> Hours(TokenStatsData data, TokenScope scope)
    {
        var m = data.Measure;
        var result = new long[24];
        foreach (var row in data.Hours.Where(r => scope.Includes(r.Provider) && r.Hour is >= 0 and < 24))
        {
            result[row.Hour] += row.Counts.Value(m);
        }
        return result;
    }
}
