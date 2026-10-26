namespace AIUsageMonitor.Core;

/// <summary>
/// 用量節奏：是否用得太快，以及照目前速度大約何時用完（UsagePace.swift、QuotaHistory.swift 的有歷史版本）。
/// 「用得太快」＝照目前速度會在重置前用完（ADR-0008 第 4 節）。
/// </summary>
public sealed record UsagePace(double AheadBy, DateTimeOffset? ExhaustsAt)
{
    /// <summary>額度剛開始時一次大請求就會超前，經過這個比例之前不判斷</summary>
    public const double MinimumElapsed = 0.1;

    public bool IsTooFast => ExhaustsAt is not null;

    /// <summary>平均速度（本額度開始至今）。資料過期、已重置、長度不明或經過不足 10% 時為 null。</summary>
    public static UsagePace? Average(UsageWindow window, bool stale, DateTimeOffset now)
    {
        if (stale || window.ElapsedFraction(now) is not { } elapsed || elapsed < MinimumElapsed
            || window.Duration is not { } duration || window.ResetsAt is not { } resetsAt)
        {
            return null;
        }
        var used = window.EffectiveUsedPct(now);
        var aheadBy = used - 100 * elapsed;
        var elapsedSeconds = elapsed * duration;
        DateTimeOffset? exhausts;
        if (used > 0 && used < 100 && elapsedSeconds > 0)
        {
            var at = SwiftTime.Add(now, (100 - used) / (used / elapsedSeconds));
            exhausts = at < resetsAt ? at : null;
        }
        else
        {
            exhausts = used >= 100 ? now : null;
        }
        return new UsagePace(aheadBy, exhausts);
    }

    /// <summary>有歷史時：以近期速度估計用完的時間；近期速度不足時退回平均速度。</summary>
    public static UsagePace? WithHistory(UsageWindow window, string provider, QuotaHistory history, bool stale, DateTimeOffset now)
    {
        if (Average(window, stale, now) is not { } baseline) return null;
        if (history.RecentRate(provider, window.Id, now) is not { } rate || window.ResetsAt is not { } resetsAt) return baseline;
        var used = window.EffectiveUsedPct(now);
        DateTimeOffset? exhausts;
        if (used >= 100)
        {
            exhausts = now;
        }
        else if (rate > 0)
        {
            var at = SwiftTime.Add(now, (100 - used) / rate);
            exhausts = at < resetsAt ? at : null;
        }
        else
        {
            exhausts = null;  // 最近沒有在用：照目前速度不會用完
        }
        return new UsagePace(baseline.AheadBy, exhausts);
    }

    /// <summary>「用得較快，約 N 分鐘後用完」（Mac 面板的 PaceBadge）。</summary>
    public string BadgeText(DateTimeOffset now)
    {
        if (ExhaustsAt is not { } at) return "用得較快";
        var minutes = Math.Max(SwiftMath.Round((at - now).TotalSeconds / 60), 1);
        return minutes >= 120 ? $"用得較快，約 {minutes / 60} 小時後用完" : $"用得較快，約 {minutes} 分鐘後用完";
    }
}

/// <summary>圓環的狀態（Mac 選單列圖示的 MenuBarState，ADR-0008 第 1 節）：不能只靠顏色區分。</summary>
public enum RingState { Normal, TooFast, Critical, Stale }

public static class RingStates
{
    /// <summary>過期優先，其次剩 &lt; 20%，再來是平均速度判斷的「太快」（圓環不讀資料庫，同 Mac 的選單列圖示）。</summary>
    public static RingState Of(UsageWindow window, bool stale, DateTimeOffset now)
    {
        if (stale) return RingState.Stale;
        if (window.EffectiveSeverity(now) == UsageSeverity.Critical) return RingState.Critical;
        return UsagePace.Average(window, stale, now)?.IsTooFast == true ? RingState.TooFast : RingState.Normal;
    }

    public static string Name(RingState state) => state switch
    {
        RingState.TooFast => "too_fast",
        RingState.Critical => "critical",
        RingState.Stale => "stale",
        _ => "normal",
    };
}

/// <summary>圓環要顯示哪個額度：自動（剩最少的）或指定「服務/額度 id」（MenuBarWindowChoice）。</summary>
public sealed record WindowChoice(string? Provider, string? WindowId)
{
    public static readonly WindowChoice Automatic = new(null, null);

    public static WindowChoice Parse(string? raw)
    {
        var parts = (raw ?? "").Split('/', 2);
        // Swift 的 split 會略過空的片段：「/x」「x/」都視為自動
        return parts.Length == 2 && parts[0].Length > 0 && parts[1].Length > 0 ? new WindowChoice(parts[0], parts[1]) : Automatic;
    }

    public bool IsAutomatic => Provider is null;

    public string RawValue => IsAutomatic ? "auto" : $"{Provider}/{WindowId}";
}

/// <summary>Swift 的 Date 以 Double 秒存放；加上非整數秒時與 DateTimeOffset（100 奈秒）一致到 1 毫秒以內就夠了。</summary>
internal static class SwiftTime
{
    public static DateTimeOffset Add(DateTimeOffset date, double seconds)
    {
        var ticks = seconds * TimeSpan.TicksPerSecond;
        if (double.IsNaN(ticks) || ticks >= DateTimeOffset.MaxValue.Ticks - date.Ticks) return DateTimeOffset.MaxValue;
        if (ticks <= DateTimeOffset.MinValue.Ticks - date.Ticks) return DateTimeOffset.MinValue;
        return date.AddTicks((long)ticks);
    }
}
