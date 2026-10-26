using System.Globalization;

namespace AIUsageMonitor.Core;

/// <summary>
/// 本機時區的日期計算，對應 Swift 以 <c>Calendar</c>（西元曆、指定時區）做的事：當天開始、加幾天、設定整點。
/// 日光節約時間的規則與 Foundation 相同（golden 有 America/New_York 與 Europe/London 的情境）：
/// 不存在的本機時間取之後第一個存在的時間（<c>matchingPolicy: .nextTime</c>），重複的本機時間取第一次（<c>.first</c>）。
/// </summary>
public static class LocalCalendar
{
    /// <summary>本機日期（時區 <paramref name="zone"/>）。</summary>
    public static DateOnly Date(DateTimeOffset instant, TimeZoneInfo zone) => DateOnly.FromDateTime(Local(instant, zone));

    public static DateTime Local(DateTimeOffset instant, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(instant, zone).DateTime;

    /// <summary>某個本機日期的開始（<c>startOfDay</c>）；午夜不存在時（在午夜切換日光節約時間的時區）是當天第一個存在的時間。</summary>
    public static DateTimeOffset StartOfDay(DateOnly date, TimeZoneInfo zone) => At(date.ToDateTime(TimeOnly.MinValue), zone);

    public static DateTimeOffset StartOfDay(DateTimeOffset instant, TimeZoneInfo zone) => StartOfDay(Date(instant, zone), zone);

    /// <summary>某天的 <paramref name="hour"/> 點整（<c>date(bySettingHour:minute:second:of:)</c>）。</summary>
    public static DateTimeOffset AtHour(DateOnly date, int hour, TimeZoneInfo zone) => At(date.ToDateTime(new TimeOnly(hour, 0)), zone);

    /// <summary>本機時間轉成時刻：不存在時取之後第一個存在的時間，重複時取第一次。</summary>
    public static DateTimeOffset At(DateTime local, TimeZoneInfo zone)
    {
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        if (zone.IsInvalidTime(local))
        {
            // 以切換前的時差解讀：02:00（不存在）→ 切換的那一刻（新時差的 03:00）。切換之間至少相隔數週，12 小時前一定是切換前
            var before = zone.GetUtcOffset(local.AddHours(-12));
            return new DateTimeOffset(local - before, TimeSpan.Zero).ToOffset(zone.GetUtcOffset(local.AddHours(12)));
        }
        if (zone.IsAmbiguousTime(local))
        {
            // 時差較大的那一個是較早的時刻（第一次）
            var offset = zone.GetAmbiguousTimeOffsets(local).Max();
            return new DateTimeOffset(local, offset);
        }
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }

    /// <summary>星期一開始的一週的第一天（<c>TokenCalendar.startOfWeek</c>，firstWeekday = 2）。</summary>
    public static DateOnly StartOfWeek(DateOnly date) => date.AddDays(-(((int)date.DayOfWeek + 6) % 7));

    /// <summary>收集器寫入的日期鍵 <c>YYYY-MM-DD</c>（西元）。</summary>
    public static string Key(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static DateOnly? ParseKey(string key)
    {
        // Swift 的 TokenCalendar.date：以「-」分開（略過空的片段）、只留整數，剛好三個；月、日超出範圍時往後進位
        var numbers = key.Split('-', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => int.TryParse(p, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : (int?)null)
            .OfType<int>().ToList();
        if (numbers.Count != 3) return null;
        try { return new DateOnly(1, 1, 1).AddYears(numbers[0] - 1).AddMonths(numbers[1] - 1).AddDays(numbers[2] - 1); }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}
