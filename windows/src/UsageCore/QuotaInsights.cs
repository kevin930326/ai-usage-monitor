namespace AIUsageMonitor.Core;

// 額度歷史畫面的計算（QuotaHistory.swift 的後半，FR-39～FR-42、ADR-0008、ADR-0009 第 4 節）。
// 計算的順序與 Swift 相同；fixtures/logic/golden.json 比對（ADR-0015 第 4 節）。

/// <summary>
/// 建議接下來用（FR-39）：某服務剩餘最少的額度剩 &lt; 20%，且另一服務對應的額度剩 ≥ 50% 時，建議另一個服務（ADR-0008 第 2 節）。
/// </summary>
public sealed record NextProviderSuggestion(string Provider, UsageWindow Window, double RemainingPct, string ExhaustedProvider)
{
    public const double LowThreshold = 20;
    public const double PlentyThreshold = 50;

    /// <summary>
    /// 資料過期、只有一個服務、兩者都充足時為 null（不顯示、不占空間）。
    /// 「對應的額度」是同 id 的額度（5 小時對 5 小時）；建議的服務沒有同 id 的額度時用它剩最少的額度。
    /// 另外要求建議的服務本身沒有任何額度剩不到 20%。
    /// </summary>
    public static NextProviderSuggestion? From(UsageSnapshot snapshot, DateTimeOffset now)
    {
        if (snapshot.IsStale(now)) return null;
        var healthy = snapshot.OrderedProviderKeys
            .Select(key => (Key: key, Usage: snapshot.Providers[key]))
            .Where(p => p.Usage.Error is null && p.Usage.VisibleWindows.Count > 0)
            .Select(p => (p.Key, Windows: p.Usage.VisibleWindows))
            .ToList();
        if (healthy.Count < 2) return null;
        // 剩最少的服務優先（依服務順序決定同分；Swift 的 min(by:) 同分保留先出現的）
        var ranked = healthy
            .Select(p => (p.Key, p.Windows, Tightest: Least(p.Windows, now)))
            .OrderBy(p => p.Tightest.EffectiveRemainingPct(now))
            .ToList();
        var low = ranked[0];
        if (!(low.Tightest.EffectiveRemainingPct(now) < LowThreshold)) return null;
        foreach (var (key, windows, tightest) in ranked.Skip(1))
        {
            if (!(tightest.EffectiveRemainingPct(now) >= LowThreshold)) continue;
            var counterpart = windows.FirstOrDefault(w => w.Id == low.Tightest.Id) ?? tightest;
            var remaining = counterpart.EffectiveRemainingPct(now);
            if (remaining >= PlentyThreshold) return new NextProviderSuggestion(key, counterpart, remaining, low.Key);
        }
        return null;
    }

    private static UsageWindow Least(IReadOnlyList<UsageWindow> windows, DateTimeOffset now)
    {
        var best = windows[0];
        foreach (var w in windows.Skip(1))
        {
            if (w.EffectiveRemainingPct(now) < best.EffectiveRemainingPct(now)) best = w;
        }
        return best;
    }
}

/// <summary>接下來的重置（FR-40）：時間軸上的一項。</summary>
/// <param name="Position">在時間軸上的位置（0＝現在，1＝8 小時後）</param>
/// <param name="JustReset">重置時間已過、收集器還沒拿到新的重置時間：畫在「現在」並標「剛重置」</param>
public sealed record UpcomingReset(string Provider, UsageWindow Window, DateTimeOffset ResetsAt, double Position, bool JustReset = false)
{
    public static readonly TimeSpan DefaultHorizon = TimeSpan.FromHours(8);

    /// <summary>
    /// 時間軸上的可見額度，依時間排序（有錯誤的服務不列）：未來 horizon 內會重置的，以及重置時間已過、還沒有新重置時間的
    /// （JustReset，位置 0）。資料過期時不標「剛重置」。
    /// </summary>
    public static IReadOnlyList<UpcomingReset> List(UsageSnapshot snapshot, DateTimeOffset now, TimeSpan? horizon = null)
    {
        var h = (horizon ?? DefaultHorizon).TotalSeconds;
        var stale = snapshot.IsStale(now);
        var result = new List<UpcomingReset>();
        foreach (var key in snapshot.OrderedProviderKeys)
        {
            var p = snapshot.Providers[key];
            if (p.Error is not null) continue;
            foreach (var w in p.VisibleWindows)
            {
                if (w.ResetsAt is not { } at || !((at - now).TotalSeconds <= h)) continue;
                if (at <= now)
                {
                    if (!stale) result.Add(new UpcomingReset(key, w, at, 0, JustReset: true));
                    continue;
                }
                result.Add(new UpcomingReset(key, w, at, (at - now).TotalSeconds / h));
            }
        }
        return result.OrderBy(r => r.ResetsAt).ToList();
    }

    /// <summary>
    /// 服務回報沒有重置時間的額度（已重置、新一輪要等下次使用才開始計時）：時間軸下方另列一行。
    /// 只列長度已知、已用 0% 的可見額度。
    /// </summary>
    public static IReadOnlyList<ProviderWindow> AwaitingStart(UsageSnapshot snapshot) =>
        snapshot.OrderedProviderKeys
            .Where(key => snapshot.Providers[key].Error is null)
            .SelectMany(key => snapshot.Providers[key].VisibleWindows
                .Where(w => w.ResetsAt is null && w.Duration is not null && w.UsedPct <= 0)
                .Select(w => new ProviderWindow(key, w)))
            .ToList();
}

/// <summary>「照目前速度，每週額度可撐到星期幾」（FR-40）。</summary>
public sealed record WeeklyForecast(string Provider, UsageWindow Window, DateTimeOffset ResetsAt, WeeklyForecast.Outcome Result,
                                    DateTimeOffset? RunsOutAt, bool UsesRecentRate)
{
    public enum Outcome
    {
        /// <summary>照目前速度在重置前用完（RunsOutAt）</summary>
        RunsOut,
        /// <summary>撐得到重置（含最近沒有在用）</summary>
        LastsUntilReset,
        /// <summary>速度資料還不夠：剛重置不久、照平均速度會用完，或額度長度不明</summary>
        NotEnoughData,
    }

    /// <summary>
    /// 每個服務的 weekly 額度一筆；資料過期、重置時間不明或已重置時不列。
    /// 1. 已用完：現在就用完。2. 有近期速度：照它算（速度 0 就是撐得到重置）。
    /// 3. 沒有近期速度：用本輪開始至今的平均速度；照它會用完時，經過一成（UsagePace.MinimumElapsed）才相信，之前「資料還不夠」。
    /// </summary>
    public static IReadOnlyList<WeeklyForecast> List(UsageSnapshot snapshot, QuotaHistory history, DateTimeOffset now)
    {
        if (snapshot.IsStale(now)) return [];
        var result = new List<WeeklyForecast>();
        foreach (var key in snapshot.OrderedProviderKeys)
        {
            var p = snapshot.Providers[key];
            if (p.Error is not null || p.VisibleWindows.FirstOrDefault(w => w.Id == "weekly") is not { } w
                || w.ResetsAt is not { } resetsAt || w.IsReset(now))
            {
                continue;
            }
            var used = w.EffectiveUsedPct(now);
            var recent = history.RecentRate(key, w.Id, now);
            DateTimeOffset? Exhausts(double rate)
            {
                if (!(rate > 0)) return null;
                var at = SwiftTime.Add(now, (100 - used) / rate);
                return at < resetsAt ? at : null;
            }
            Outcome outcome;
            DateTimeOffset? runsOut = null;
            if (used >= 100)
            {
                outcome = Outcome.RunsOut;
                runsOut = now;
            }
            else if (recent is { } rate)
            {
                runsOut = Exhausts(rate);
                outcome = runsOut is null ? Outcome.LastsUntilReset : Outcome.RunsOut;
            }
            else if (w.ElapsedFraction(now) is { } elapsed && w.Duration is { } duration && elapsed > 0)
            {
                if (Exhausts(used / (elapsed * duration)) is { } at)
                {
                    if (elapsed >= UsagePace.MinimumElapsed)
                    {
                        outcome = Outcome.RunsOut;
                        runsOut = at;
                    }
                    else
                    {
                        outcome = Outcome.NotEnoughData;
                    }
                }
                else
                {
                    outcome = Outcome.LastsUntilReset;
                }
            }
            else
            {
                outcome = Outcome.NotEnoughData;
            }
            result.Add(new WeeklyForecast(key, w, resetsAt, outcome, runsOut, recent is not null));
        }
        return result;
    }

    private static readonly string[] Weekdays = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"];

    /// <summary>「週五晚上」：星期＋時段（凌晨 0–6、早上 6–12、下午 12–18、晚上 18–24），本機時區。</summary>
    public static string DayPart(DateTimeOffset date, TimeZoneInfo zone)
    {
        var local = LocalCalendar.Local(date, zone);
        var hour = local.Hour;
        var part = hour < 6 ? "凌晨" : hour < 12 ? "早上" : hour < 18 ? "下午" : "晚上";
        return Weekdays[(int)local.DayOfWeek] + part;
    }
}

/// <summary>本週額度走勢（FR-41）。</summary>
public sealed class QuotaTrend
{
    public readonly record struct Point(DateTimeOffset Ts, double RemainingPct);

    /// <summary>這一輪的開始與結束（重置時間）；x 軸的範圍</summary>
    public TimeRange Span { get; }

    /// <summary>這一輪的剩餘 %（依時間排序）</summary>
    public IReadOnlyList<Point> Points { get; }

    /// <summary>沒有紀錄的時段（斜線）</summary>
    public IReadOnlyList<TimeRange> Gaps { get; }

    public bool HasEnoughData => Points.Count >= QuotaHistory.MinimumSamples;

    /// <summary>選定額度的走勢。額度長度或重置時間不明時以最近 7 天為範圍、不畫預期。</summary>
    public QuotaTrend(string provider, UsageWindow window, QuotaHistory history, DateTimeOffset now)
    {
        DateTimeOffset start, end;
        if (window.ResetsAt is { } resetsAt && window.Duration is { } duration && !window.IsReset(now))
        {
            end = resetsAt;
            start = SwiftTime.Add(resetsAt, -duration);
        }
        else
        {
            end = now;
            start = now.AddDays(-7);
        }
        Span = new TimeRange(start, end);
        Points = QuotaHistory.CurrentCycle(history.SamplesFor(provider, window.Id))
            .Where(s => s.Ts >= start && s.Ts <= now)
            .Select(s => new Point(s.Ts, Math.Min(Math.Max(100 - s.UsedPct, 0), 100)))
            .ToList();
        Gaps = history.Gaps(new TimeRange(start, QuotaHistory.Min(now, end)));
    }

    /// <summary>照時間的預期剩餘 %（虛線）：開始時 100%，重置時 0%。</summary>
    public double ExpectedRemaining(DateTimeOffset date)
    {
        if (!(Span.Duration > 0)) return 100;
        return 100 * (1 - Math.Min(Math.Max((date - Span.Start).TotalSeconds / Span.Duration, 0), 1));
    }
}

/// <summary>
/// 每小時消耗的額度 %（FR-42，ADR-0011 第一層）：同一額度相鄰兩筆的正差值；重置時以新值計，並只分到重置時間之後。
/// 兩筆之間超過 15 分鐘（沒有紀錄）時，差值平均分配到這段時間並標成「估計」；這段時間中有重置時不分配，那幾個小時標成「沒有紀錄」。
/// </summary>
public sealed class QuotaConsumption
{
    /// <param name="Start">這個小時的開始（本機時區的整點）</param>
    /// <param name="Consumed">消耗的百分點；null＝沒有紀錄</param>
    /// <param name="Estimated">含平均分配的估計值（畫斜線）</param>
    public readonly record struct Hour(DateTimeOffset Start, double? Consumed, bool Estimated);

    public readonly record struct DayTotal(DateTimeOffset Start, double? Consumed, bool Estimated);

    /// <summary>熱力圖的色階數（UsagePalette.heatmapLevels）</summary>
    public const int HeatmapLevels = 5;

    /// <summary>依時間排序的每小時資料，涵蓋 Days 天（今天在最後），每天固定 24 格</summary>
    public IReadOnlyList<Hour> Hours { get; }

    public int Days { get; }

    /// <summary>範圍內這個額度的樣本數</summary>
    public int SampleCount { get; }

    /// <summary>至少 2 筆樣本才畫（ADR-0009 第 8 節），否則顯示骨架畫面</summary>
    public bool HasEnoughData => SampleCount >= QuotaHistory.MinimumSamples && Hours.Any(h => h.Consumed is not null);

    /// <summary>單一小時的最大消耗（色階的上限，至少 1 個百分點）</summary>
    public double Peak => Math.Max(Hours.Select(h => h.Consumed).OfType<double>().DefaultIfEmpty(0).Max(), 1);

    /// <summary>熱力圖的色階：0（沒有消耗）～5，依占 Peak 的比例等分</summary>
    public int Level(double consumed)
    {
        if (!(consumed > 0)) return 0;
        return Math.Min(Math.Max((int)Math.Ceiling(Math.Min(consumed / Peak, 1) * HeatmapLevels), 1), HeatmapLevels);
    }

    /// <summary>每天的合計（Days 筆，今天在最後）；整天都沒有紀錄時為 null。</summary>
    public IReadOnlyList<DayTotal> DailyTotals
    {
        get
        {
            var result = new List<DayTotal>();
            for (var i = 0; i < Hours.Count; i += 24)
            {
                var day = Hours.Skip(i).Take(24).ToList();
                var known = day.Select(h => h.Consumed).OfType<double>().ToList();
                double? sum = null;
                if (known.Count > 0)
                {
                    double total = 0;
                    foreach (var k in known) total += k;  // 依序相加，與 Swift 的 reduce 相同
                    sum = total;
                }
                result.Add(new DayTotal(day[0].Start, sum, day.Any(h => h.Estimated)));
            }
            return result;
        }
    }

    public QuotaConsumption(string provider, string windowId, QuotaHistory history, DateTimeOffset now, TimeZoneInfo zone, int days = 7)
    {
        Days = days;
        var today = LocalCalendar.Date(now, zone);
        var first = today.AddDays(-(days - 1));
        // 每個本機日期固定 24 格（第 h 格＝當天 h 點開始到下一格開始），日期與小時才不會錯位。
        // 日光節約時間開始那天不存在的小時是 0 長度的格子；結束那天重複的小時併在同一格（2 小時）。
        var spans = new List<TimeRange>();
        for (var day = 0; day < days; day++)
        {
            var date = first.AddDays(day);
            var dayStart = LocalCalendar.StartOfDay(date, zone);
            var nextDay = LocalCalendar.StartOfDay(date.AddDays(1), zone);
            var starts = Enumerable.Range(0, 24).Select(h => h == 0 ? dayStart : LocalCalendar.AtHour(date, h, zone)).Append(nextDay).ToList();
            for (var h = 0; h < 24; h++)
            {
                var start = QuotaHistory.Min(starts[h], nextDay);
                spans.Add(new TimeRange(start, QuotaHistory.Max(QuotaHistory.Min(starts[h + 1], nextDay), start)));
            }
        }
        var consumed = new double?[spans.Count];
        var estimated = new bool[spans.Count];
        var unknown = new bool[spans.Count];
        var rangeStart = LocalCalendar.StartOfDay(first, zone);

        // 有收集紀錄的時段才算「有紀錄」，沒有使用時是 0
        for (var i = 0; i < spans.Count; i++)
        {
            var span = spans[i];
            if (!(span.Start < now && span.Duration > 0)) continue;
            var observed = new TimeRange(span.Start, QuotaHistory.Min(span.End, now));
            var missing = history.Gaps(observed).Sum(g => g.Duration);
            if (missing < observed.Duration) consumed[i] = 0;
        }

        var series = history.SamplesFor(provider, windowId);
        SampleCount = series.Count(s => s.Ts >= rangeStart);
        for (var j = 1; j < series.Count; j++)
        {
            var (a, b) = (series[j - 1], series[j]);
            if (!(b.Ts > rangeStart)) continue;
            var segment = new TimeRange(a.Ts, b.Ts);
            var reset = QuotaHistory.IsReset(a, b);
            var delta = reset ? Math.Max(b.UsedPct, 0) : Math.Max(b.UsedPct - a.UsedPct, 0);
            var isGap = segment.Duration > QuotaHistory.GapThreshold.TotalSeconds;
            if (isGap && reset)
            {
                // 空檔中有重置：不分配，這段時間標成沒有紀錄
                for (var i = 0; i < spans.Count; i++)
                {
                    if (spans[i].Overlap(segment) > 0) unknown[i] = true;
                }
                continue;
            }
            // 重置時間落在兩筆之間：新一輪的用量只分到重置之後
            var allocation = segment;
            if (reset && a.ResetsAt is { } resetsAt && resetsAt > a.Ts && resetsAt < b.Ts) allocation = new TimeRange(resetsAt, b.Ts);
            if (!(allocation.Duration > 0)) continue;
            for (var i = 0; i < spans.Count; i++)
            {
                var overlap = spans[i].Overlap(allocation);
                if (!(overlap > 0)) continue;
                consumed[i] = (consumed[i] ?? 0) + delta * overlap / allocation.Duration;
                if (isGap) estimated[i] = true;
            }
        }
        Hours = spans.Select((s, i) => unknown[i]
            ? new Hour(s.Start, null, false)
            : new Hour(s.Start, consumed[i], estimated[i] && consumed[i] is not null)).ToList();
    }
}
