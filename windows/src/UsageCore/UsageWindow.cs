using System.Globalization;

namespace AIUsageMonitor.Core;

/// <summary>
/// 一個額度（5 小時、每週…），對應 UsageKit 的 <c>UsageWindow</c> 與 UsageWindow+Reset.swift、UsagePace.swift 的純計算。
/// 計算的順序與 Swift 相同（浮點結果一致，fixtures/logic/golden.json 比對）。
/// </summary>
public sealed record UsageWindow(string Id, string Label, double UsedPct, DateTimeOffset? ResetsAt = null, bool Hidden = false)
{
    /// <summary>重置時間已過（FR-26）。</summary>
    public bool IsReset(DateTimeOffset now) => ResetsAt is { } r && r <= now;

    /// <summary>考慮重置後的已用百分比：重置時間已過就視為 0%，其他限制在 0…100。</summary>
    public double EffectiveUsedPct(DateTimeOffset now) => IsReset(now) ? 0 : Math.Min(Math.Max(UsedPct, 0), 100);

    public double EffectiveRemainingPct(DateTimeOffset now) => 100 - EffectiveUsedPct(now);

    public UsageSeverity EffectiveSeverity(DateTimeOffset now) => Severity.Of(EffectiveRemainingPct(now));

    /// <summary>
    /// 額度長度，由 id 推得（收集器 window_label 的規則）：five_hour 5 小時、weekly／weekly_* 7 天、&lt;n&gt;h、&lt;n&gt;m；其他為 null。
    /// </summary>
    public double? Duration
    {
        get
        {
            if (Id == "five_hour") return 5 * 3600;
            if (Id == "weekly" || Id.StartsWith("weekly_", StringComparison.Ordinal)) return 7 * 86400;
            foreach (var (suffix, unit) in new[] { ("h", 3600.0), ("m", 60.0) })
            {
                if (!Id.EndsWith(suffix, StringComparison.Ordinal)) continue;
                // Swift 的 Int(String)（64 位元）接受前面的 + 或 -，不接受空白
                var digits = Id[..^1];
                if (digits.Length > 0 && !digits.Any(char.IsWhiteSpace)
                    && long.TryParse(digits, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) && n > 0)
                {
                    return n * unit;
                }
            }
            return null;
        }
    }

    /// <summary>額度已經過的比例（0…1）；長度或重置時間不明、或已重置時為 null。</summary>
    public double? ElapsedFraction(DateTimeOffset now)
    {
        if (Duration is not { } duration || ResetsAt is not { } resetsAt || IsReset(now)) return null;
        return Math.Min(Math.Max(1 - (resetsAt - now).TotalSeconds / duration, 0), 1);
    }

    /// <summary>距離重置的剩餘時間占額度長度的比例（雙圓環的內圈）。</summary>
    public double? TimeRemainingFraction(DateTimeOffset now) => ElapsedFraction(now) is { } e ? 1 - e : null;

    /// <summary>照時間比例應剩多少 %（預期進度標記的位置）。</summary>
    public double? ExpectedRemainingPct(DateTimeOffset now) => ElapsedFraction(now) is { } e ? 100 * (1 - e) : null;

    /// <summary>預期進度標記的說明：「照時間比例，現在應剩 20%」。</summary>
    public string? ExpectedRemainingDescription(DateTimeOffset now) =>
        ExpectedRemainingPct(now) is { } pct ? ExpectedDescription(pct) : null;

    public static string ExpectedDescription(double pct) =>
        $"照時間比例，現在應剩 {SwiftMath.Round(pct).ToString(CultureInfo.InvariantCulture)}%";
}

/// <summary>依剩餘比例分級（FR-16）：&lt; 20% 危險（紅色），其他為正常。</summary>
public enum UsageSeverity { Normal, Critical }

public static class Severity
{
    public const double CriticalBelow = 20;

    public static UsageSeverity Of(double remainingPct) => remainingPct < CriticalBelow ? UsageSeverity.Critical : UsageSeverity.Normal;
}

/// <summary>Swift 的 <c>Double.rounded()</c>（0.5 進位、遠離 0）。C# 的 Math.Round 預設是銀行家捨入，不能直接用。</summary>
public static class SwiftMath
{
    public static long Round(double value) => (long)Math.Round(value, MidpointRounding.AwayFromZero);
}
