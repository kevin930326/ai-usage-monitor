using System.Globalization;
using System.Numerics;

namespace AIUsageMonitor.Core;

/// <summary>到某個時間還有多久，精確到分鐘（UsageWindow+Reset.swift 的 ResetCountdown）。</summary>
public static class ResetCountdown
{
    /// <summary>「2天 23小時」「1小時 39分鐘」「12分鐘」「不到 1 分鐘」；時間已過回傳 null（畫面顯示「已重置」）。</summary>
    public static string? Text(DateTimeOffset until, DateTimeOffset now)
    {
        var seconds = (until - now).TotalSeconds;
        if (!(seconds > 0)) return null;
        var minutes = (long)(seconds / 60);  // Swift 的 Int(Double) 向 0 截斷
        long days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60;
        if (days > 0) return hours > 0 ? $"{days}天 {hours}小時" : $"{days}天";
        if (hours > 0) return mins > 0 ? $"{hours}小時 {mins}分鐘" : $"{hours}小時";
        return minutes > 0 ? $"{mins}分鐘" : "不到 1 分鐘";
    }

    /// <summary>「12分鐘前更新」；不到 1 分鐘為「剛剛更新」。</summary>
    public static string UpdatedText(DateTimeOffset since, DateTimeOffset now)
    {
        if ((now - since).TotalSeconds < 60 || Text(now, since) is not { } elapsed) return "剛剛更新";
        return $"{elapsed}前更新";
    }
}

/// <summary>Token 數字的文字（TokenStats.swift 的 TokenFormat）。</summary>
public static class TokenFormat
{
    /// <summary>「9,999」「1.23萬」「12.3萬」「1,470萬」「3.85億」：一萬以上用萬／億、三位有效數字，不到一萬顯示整數。</summary>
    public static string Short(long value)
    {
        var magnitude = value == long.MinValue ? (ulong)long.MaxValue + 1 : (ulong)Math.Abs(value);
        if (magnitude < 10_000) return Full(value);
        var scaled = Significant(magnitude, 10_000);
        var unit = "萬";
        if (scaled.Whole >= 10_000)  // 包含四捨五入後進位到一億（9,999.5 萬 → 1 億）
        {
            scaled = Significant(magnitude, 100_000_000);
            unit = "億";
        }
        return (value < 0 ? "-" : "") + scaled.Text + unit;
    }

    /// <summary>「1 小時 23 分」「45 分」「30 秒」</summary>
    public static string Duration(long seconds)
    {
        if (seconds < 60) return $"{seconds} 秒";
        var minutes = seconds / 60;
        if (minutes < 60) return $"{minutes} 分";
        long h = minutes / 60, m = minutes % 60;
        return m == 0 ? $"{h} 小時" : $"{h} 小時 {m} 分";
    }

    /// <summary>完整數字加千分位：「12,345,678」</summary>
    public static string Full(long value) => value.ToString("#,0", CultureInfo.InvariantCulture);

    private static string FullUnsigned(BigInteger value) => value.ToString("#,0", CultureInfo.InvariantCulture);

    /// <summary>value / unit 四捨五入到三位有效數字（以整數計算），回傳整數部分與文字；小數尾端的 0 去掉。</summary>
    private static (BigInteger Whole, string Text) Significant(ulong value, ulong unit)
    {
        var digits = (value / unit).ToString(CultureInfo.InvariantCulture).Length;
        BigInteger v = value, u = unit;
        if (digits >= 3)
        {
            var scale = BigInteger.Pow(10, digits - 3);
            var step = u * scale;
            var whole = (v / step + (v % step >= step - step / 2 ? 1 : 0)) * scale;
            return (whole, FullUnsigned(whole));
        }
        var decimals = 3 - digits;
        var scaleD = BigInteger.Pow(10, decimals);
        var stepD = u / scaleD;
        var rounded = v / stepD + (v % stepD >= stepD - stepD / 2 ? 1 : 0);
        var fraction = (rounded % scaleD).ToString(CultureInfo.InvariantCulture).PadLeft(decimals, '0').TrimEnd('0');
        var w = rounded / scaleD;
        return (w, fraction.Length == 0 ? w.ToString(CultureInfo.InvariantCulture) : $"{w}.{fraction}");
    }
}

/// <summary>Windows App 自己的文字（Mac 沒有對應的 UsageKit 函式）。</summary>
public static class RingText
{
    /// <summary>圓環的滑鼠提示：「Claude 每週 剩 63% · 4天 2小時後重置」；已重置為「已重置」，沒有重置時間時只有前半。</summary>
    public static string Tooltip(ProviderWindow item, bool stale, DateTimeOffset now)
    {
        var w = item.Window;
        var text = $"{item.DisplayName} 剩 {SwiftMath.Round(w.EffectiveRemainingPct(now))}%";
        if (w.IsReset(now)) text += " · 已重置";
        else if (w.ResetsAt is { } r && ResetCountdown.Text(r, now) is { } countdown) text += $" · {countdown}後重置";
        var state = RingStates.Of(w, stale, now);
        return state switch
        {
            RingState.TooFast => text + " · 用得較快",
            RingState.Critical => text + " · 剩不到 20%",
            RingState.Stale => text + " · 資料已過期",
            _ => text,
        };
    }

    /// <summary>螢幕閱讀程式用（同 Mac 選單列圖示的 accessibilityText）。</summary>
    public static string AccessibilityText(ProviderWindow item, bool stale, DateTimeOffset now, bool isLeast)
    {
        var text = $"{(isLeast ? "剩餘最少的額度：" : "")}{item.DisplayName}，剩 {SwiftMath.Round(item.Window.EffectiveRemainingPct(now))}%";
        return RingStates.Of(item.Window, stale, now) switch
        {
            RingState.TooFast => text + "，用得較快",
            RingState.Critical => text + "，剩不到 20%",
            RingState.Stale => text + "，資料已過期",
            _ => text,
        };
    }

    /// <summary>頁首的更新時間：「09:30 更新」；過期時「資料已過期 · 09:30 更新」（設計 skill 第 6 節）。</summary>
    public static string Updated(UsageSnapshot snapshot, DateTimeOffset now, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(snapshot.UpdatedAt, zone).ToString("HH:mm", CultureInfo.InvariantCulture);
        return snapshot.IsStale(now) ? $"資料已過期 · {local} 更新" : $"{local} 更新";
    }
}
