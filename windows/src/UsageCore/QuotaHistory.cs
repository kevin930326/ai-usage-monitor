namespace AIUsageMonitor.Core;

/// <summary>history.sqlite3 的 quota_samples 一列：某次收集時某個額度的已用 %。</summary>
public sealed record QuotaSample(DateTimeOffset Ts, string Provider, string WindowId, double UsedPct, DateTimeOffset? ResetsAt);

/// <summary>collector_runs 的一列。Runs &gt; 1 是降採樣後代表一整個小時的列（35 天前的資料）。</summary>
public sealed record CollectorRun(DateTimeOffset Ts, int Ok = 1, int Runs = 1);

/// <summary>一段時間（開始、結束），對應 Swift 的 <c>TimeSpan</c>（C# 已有 System.TimeSpan，改名）。結束可以早於開始。</summary>
public readonly record struct TimeRange(DateTimeOffset Start, DateTimeOffset End)
{
    public double Duration => (End - Start).TotalSeconds;

    public double Overlap(TimeRange other)
    {
        var end = End < other.End ? End : other.End;
        var start = Start > other.Start ? Start : other.Start;
        return Math.Max(0, (end - start).TotalSeconds);
    }
}

/// <summary>
/// 額度歷史的純計算（QuotaHistory.swift，ADR-0008 第 4 節、ADR-0009 第 4 節）：沒有紀錄的時段、重置判斷、近期速度。
/// 建議接下來用、重置時間軸、每週預測、走勢、額度消耗在 QuotaInsights.cs。
/// </summary>
public sealed class QuotaHistory
{
    /// <summary>兩次收集之間超過這麼久就是「沒有紀錄」（ADR-0009 第 4 節）</summary>
    public static readonly TimeSpan GapThreshold = TimeSpan.FromMinutes(15);

    /// <summary>resets_at 前後變動不到這麼多視為同一輪（Claude 的重置時間從文字解析，可能有分鐘以內的差異）</summary>
    public static readonly TimeSpan ResetTolerance = TimeSpan.FromMinutes(10);

    /// <summary>畫圖至少要有的樣本數（ADR-0009 第 8 節：≥ 2 筆後開始畫）</summary>
    public const int MinimumSamples = 2;

    public const int RecentMinimumSamples = 4;

    public static readonly QuotaHistory Empty = new([]);

    public IReadOnlyList<QuotaSample> Samples { get; }

    public IReadOnlyList<CollectorRun> Runs { get; }

    public QuotaHistory(IEnumerable<QuotaSample> samples, IEnumerable<CollectorRun>? runs = null)
    {
        // Swift 的 sorted 不保證穩定；同一時間的兩筆在收集器裡不會出現（主鍵含時間）
        Samples = samples.OrderBy(s => s.Ts).ToList();
        Runs = (runs ?? []).OrderBy(r => r.Ts).ToList();
    }

    public IReadOnlyList<QuotaSample> SamplesFor(string provider, string windowId) =>
        Samples.Where(s => s.Provider == provider && s.WindowId == windowId).ToList();

    /// <summary>
    /// range 內沒有收集器紀錄的時段（電腦睡眠、關機、收集器停止）。
    /// 降採樣的列（Runs &gt; 1）視為涵蓋它所在的整點到它的時間。
    /// </summary>
    public IReadOnlyList<TimeRange> Gaps(TimeRange range)
    {
        if (!(range.Duration > 0)) return [];
        var threshold = GapThreshold.TotalSeconds;
        var covered = Runs.Select(run =>
        {
            var start = run.Runs > 1
                ? DateTimeOffset.FromUnixTimeSeconds((long)Math.Floor(run.Ts.ToUnixTimeMilliseconds() / 1000.0 / 3600) * 3600)
                : run.Ts;
            return new TimeRange(start, run.Ts);
        }).OrderBy(s => s.Start).ToList();
        var result = new List<TimeRange>();
        var cursor = range.Start;
        // 範圍開始之前最後一次收集若在門檻內，從那次開始算
        var before = covered.Where(s => s.End <= range.Start).ToList();
        if (before.Count > 0) cursor = before[^1].End;
        foreach (var span in covered.Where(s => s.End > range.Start))
        {
            if ((span.Start - cursor).TotalSeconds > threshold)
            {
                result.Add(new TimeRange(Max(cursor, range.Start), Min(span.Start, range.End)));
            }
            cursor = Max(cursor, span.End);
            if (cursor >= range.End) break;
        }
        if ((range.End - cursor).TotalSeconds > threshold) result.Add(new TimeRange(Max(cursor, range.Start), range.End));
        return result.Where(g => g.Duration > 0).ToList();
    }

    internal static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    internal static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

    /// <summary>相鄰兩筆之間是否重置：resets_at 改變超過容許誤差（或一筆有、一筆沒有），或已用 % 下降到一半以下（含一半）。</summary>
    public static bool IsReset(QuotaSample a, QuotaSample b)
    {
        if (ResetsAtChanged(a, b)) return true;
        return b.UsedPct < a.UsedPct && b.UsedPct <= a.UsedPct / 2;
    }

    private static bool ResetsAtChanged(QuotaSample a, QuotaSample b) => (a.ResetsAt, b.ResetsAt) switch
    {
        ({ } x, { } y) => Math.Abs((y - x).TotalSeconds) > ResetTolerance.TotalSeconds,
        (null, null) => false,
        _ => true,
    };

    /// <summary>最後一次重置之後（目前這一輪）的樣本。</summary>
    public static IReadOnlyList<QuotaSample> CurrentCycle(IReadOnlyList<QuotaSample> samples)
    {
        for (var i = samples.Count - 1; i >= 1; i--)
        {
            if (IsReset(samples[i - 1], samples[i])) return samples.Skip(i).ToList();
        }
        return samples;
    }

    /// <summary>近期速度要看多久：5 小時額度看最近 60 分鐘、每週額度看最近 24 小時；其他長度不用近期速度。</summary>
    public static TimeSpan? RecentLookback(string windowId)
    {
        if (windowId == "five_hour") return TimeSpan.FromHours(1);
        if (windowId == "weekly" || windowId.StartsWith("weekly_", StringComparison.Ordinal)) return TimeSpan.FromDays(1);
        return null;
    }

    /// <summary>近期速度至少要涵蓋多久：5 小時額度 30 分鐘；每週額度 12 小時。</summary>
    public static TimeSpan RecentMinimumSpan(string windowId) =>
        windowId == "five_hour" ? TimeSpan.FromMinutes(30) : TimeSpan.FromHours(12);

    /// <summary>
    /// 近期速度（每秒消耗的百分點）：同一輪、回看範圍內至少 4 筆，且跨度達 RecentMinimumSpan；不足時為 null。
    /// 速度是相鄰兩筆正差值的總和除以時間（小幅下修那一段記 0）。
    /// </summary>
    public double? RecentRate(string provider, string windowId, DateTimeOffset now)
    {
        if (RecentLookback(windowId) is not { } lookback) return null;
        var cycle = CurrentCycle(SamplesFor(provider, windowId));
        var from = now - lookback;
        var recent = cycle.Where(s => s.Ts >= from && s.Ts <= now).ToList();
        if (recent.Count < RecentMinimumSamples) return null;
        var span = (recent[^1].Ts - recent[0].Ts).TotalSeconds;
        if (span < RecentMinimumSpan(windowId).TotalSeconds) return null;
        double consumed = 0;
        for (var i = 1; i < recent.Count; i++) consumed += Math.Max(recent[i].UsedPct - recent[i - 1].UsedPct, 0);
        return consumed / span;
    }
}
