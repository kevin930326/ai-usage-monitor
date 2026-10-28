namespace AIUsageMonitor.Core;

/// <summary>
/// 額度預測（ADR-0018 第 1 節，QuotaForecast.swift）：照近期速度推算「約幾點幾分用完」，以及比過去 7 天同時段快幾倍。
/// 只在資料足夠、而且會在重置前用完時才有值；資料不足時不退回平均速度（不猜）。
/// 同一套規則在 Swift 與收集器的 forecast.py，fixtures/forecast/ 三邊跑同一份 golden。
/// </summary>
/// <param name="ExhaustsAt">預計用完的時間</param>
/// <param name="Urgent">不到 60 分鐘就用完（紅色；其他黃色）</param>
/// <param name="Faster">比平常快幾倍（小數一位、無條件捨去）；不到 1.5 倍或平常的資料不足時為 null</param>
public sealed record QuotaForecast(DateTimeOffset ExhaustsAt, bool Urgent, double? Faster)
{
    public static readonly TimeSpan UrgentWithin = TimeSpan.FromHours(1);
    public const double FasterThreshold = 1.5;
    public const int BaselineDays = 7;
    public const int BaselineMinimumDays = 3;

    /// <summary>某個額度的預測；任何條件不符（過期、隱藏、沒有重置時間、已用完、資料不足、不會在重置前用完）為 null</summary>
    public static QuotaForecast? From(UsageWindow window, string provider, QuotaHistory history, bool stale, DateTimeOffset now)
    {
        if (stale || window.Hidden || window.ResetsAt is not { } resetsAt || resetsAt <= now
            || QuotaHistory.RecentLookback(window.Id) is null) return null;
        var used = window.EffectiveUsedPct(now);
        if (used >= 100 || history.RecentRate(provider, window.Id, now) is not { } rate || rate <= 0) return null;
        // 以最後一筆樣本的時間為起點：兩次收集之間不會每分鐘往後漂一分鐘
        var last = history.SamplesFor(provider, window.Id).LastOrDefault(s => s.Ts <= now);
        var at = (last?.Ts ?? now).AddSeconds((100 - used) / rate);
        if (at <= now || at >= resetsAt) return null;
        double? faster = null;
        if (UsualRate(history, provider, window.Id, now) is { } usual && usual > 0)
        {
            var ratio = Math.Floor(rate / usual * 10) / 10;
            if (ratio >= FasterThreshold) faster = ratio;
        }
        return new QuotaForecast(at, (at - now) < UrgentWithin, faster);
    }

    /// <summary>
    /// 平常的速度：過去 7 天每一天同一段回看範圍（往前推整天數）的速度，各天的資料門檻同近期速度
    /// （至少 4 筆、跨度足夠）；至少 3 天有資料時取中位數，否則 null。跨過重置的那一段不算消耗。
    /// </summary>
    public static double? UsualRate(QuotaHistory history, string provider, string windowId, DateTimeOffset now)
    {
        if (QuotaHistory.RecentLookback(windowId) is not { } lookback) return null;
        var all = history.SamplesFor(provider, windowId);
        var rates = new List<double>();
        for (var day = 1; day <= BaselineDays; day++)
        {
            var end = now.AddDays(-day);
            var from = end - lookback;
            var span = all.Where(s => s.Ts >= from && s.Ts <= end).ToList();
            if (span.Count < QuotaHistory.RecentMinimumSamples) continue;
            var seconds = (span[^1].Ts - span[0].Ts).TotalSeconds;
            if (seconds < QuotaHistory.RecentMinimumSpan(windowId).TotalSeconds) continue;
            double used = 0;
            for (var i = 1; i < span.Count; i++)
            {
                if (!QuotaHistory.IsReset(span[i - 1], span[i])) used += Math.Max(span[i].UsedPct - span[i - 1].UsedPct, 0);
            }
            rates.Add(used / seconds);
        }
        if (rates.Count < BaselineMinimumDays) return null;
        rates.Sort();
        var mid = rates.Count / 2;
        return rates.Count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2;
    }

    /// <summary>
    /// 畫面用的預測（Windows App 與 iPhone 一樣用快照裡收集器算好的，同一套規則、最多 5 分鐘前）：
    /// 過期、已經過了、或不在重置前的不用，緊急與否照現在的時間重算。對應 Swift 的 <c>QuotaForecast.current</c>（沒有歷史時）。
    /// </summary>
    public static QuotaForecast? Current(UsageWindow window, bool stale, DateTimeOffset now)
    {
        if (stale || window.Hidden || window.Forecast is not { } f || f.ExhaustsAt <= now
            || window.ResetsAt is not { } resetsAt || f.ExhaustsAt >= resetsAt || window.EffectiveUsedPct(now) >= 100) return null;
        return f with { Urgent = (f.ExhaustsAt - now) < UrgentWithin };
    }

    /// <summary>「照目前速度約 14:32 用完」；不是今天時「照目前速度約明天 09:05 用完」「…約週五 18:00 用完」</summary>
    public string Text(DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        var clock = Clock(ExhaustsAt, now, zone);
        return $"照目前速度約{(char.IsDigit(clock[0]) ? " " : "")}{clock} 用完";
    }

    /// <summary>「比平常快 2.1 倍」；沒有倍數時 null</summary>
    public string? FasterText => Faster is { } f ? $"比平常快 {f.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} 倍" : null;

    /// <summary>一行的完整說法：「照目前速度約 14:32 用完・比平常快 2.1 倍」</summary>
    public string Line(DateTimeOffset now, TimeZoneInfo? zone = null) =>
        FasterText is { } faster ? $"{Text(now, zone)}・{faster}" : Text(now, zone);

    /// <summary>朗讀用：緊急只靠顏色與符號分辨不出來，加上「不到 1 小時」（同 Swift 的 spokenLine）</summary>
    public string SpokenLine(DateTimeOffset now, TimeZoneInfo? zone = null) => Line(now, zone) + (Urgent ? "，不到 1 小時" : "");

    /// <summary>小地方的短說法：「約 14:32 用完・快 2.1 倍」</summary>
    public string ShortLine(DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        var clock = Clock(ExhaustsAt, now, zone);
        var head = $"約{(char.IsDigit(clock[0]) ? " " : "")}{clock} 用完";
        return Faster is { } f ? $"{head}・快 {f.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} 倍" : head;
    }

    /// <summary>「14:32」「明天 09:05」「週五 18:00」（本機時區）</summary>
    public static string Clock(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var local = TimeZoneInfo.ConvertTime(date, zone);
        var today = TimeZoneInfo.ConvertTime(now, zone);
        var time = local.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        var days = (local.Date - today.Date).Days;
        if (days <= 0) return time;
        if (days == 1) return $"明天 {time}";
        string[] names = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"];
        return $"{names[(int)local.DayOfWeek]} {time}";
    }
}
