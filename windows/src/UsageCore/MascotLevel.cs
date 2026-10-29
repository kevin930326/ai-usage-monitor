namespace AIUsageMonitor.Core;

/// <summary>
/// 角色養成（ADR-0020，MascotLevel.swift）：從 level_days（每天所有電腦合併的主數字，收集器維護、只增不減）
/// 算經驗值、等級與連續天數。fixtures/level/ 的 golden 和 Swift 跑同一份。
/// <list type="bullet">
/// <item>活躍日：tokens &gt; 0。每天 10 點，加用量 min(10, ⌊log₂(tokens ÷ 10,000)⌋ + 1)（滿 1 萬才有），
/// 加連續 min(5, k − 1)（連續活躍的第 k 天）；一天最多 25 點。</item>
/// <item>等級 L 升到 L + 1 要 50 × L 點；達到 L 的累計門檻 25 × L × (L − 1)；最高 99。</item>
/// <item>日期是 YYYY-MM-DD，以日曆日計算（不經過時區），格式不對的略過。</item>
/// </list>
/// </summary>
public sealed record MascotLevel(long Xp, int Level, long ToNext, double Progress, int CurrentStreak, int LongestStreak, int ActiveDays)
{
    public const int MaxLevel = 99;
    private const long ActivePoints = 10;
    private const long VolumeUnit = 10_000;
    private const long MaxVolume = 10;
    private const long MaxStreakBonus = 5;

    /// <summary>沒有任何活躍日時 null（新安裝、還沒掃描完）</summary>
    public static MascotLevel? From(IReadOnlyDictionary<string, long> days, string today)
    {
        var active = new List<(int Day, long Tokens)>();
        foreach (var (text, tokens) in days)
            if (tokens > 0 && DayNumber(text) is { } day) active.Add((day, tokens));
        if (active.Count == 0) return null;
        active.Sort((a, b) => a.Day.CompareTo(b.Day));

        long xp = 0;
        int run = 0, longest = 0;
        int? previous = null;
        foreach (var (day, tokens) in active)
        {
            run = previous == day - 1 ? run + 1 : 1;
            longest = Math.Max(longest, run);
            previous = day;
            xp += ActivePoints + Volume(tokens) + Math.Min(MaxStreakBonus, run - 1);
        }

        // 目前的連續：從今天（今天還沒用時從昨天）往回數。時鐘曾經調快而留下「未來」的日子時不受影響
        var set = active.Select(a => a.Day).ToHashSet();
        var current = 0;
        if (DayNumber(today) is { } todayNumber)
        {
            int? start = set.Contains(todayNumber) ? todayNumber : set.Contains(todayNumber - 1) ? todayNumber - 1 : null;
            for (var d = start; d is { } value && set.Contains(value); d = value - 1) current++;
        }

        var level = 1;
        while (level < MaxLevel && Threshold(level + 1) <= xp) level++;
        var toNext = level == MaxLevel ? 0 : Threshold(level + 1) - xp;
        var progress = level == MaxLevel ? 1 : (double)(xp - Threshold(level)) / (50L * level);
        return new MascotLevel(xp, level, toNext, progress, current, longest, active.Count);
    }

    /// <summary>達到等級 L 的累計經驗值</summary>
    public static long Threshold(int level) => 25L * level * (level - 1);

    /// <summary>用量加分：1 萬→1、2 萬→2、4 萬→3 … 512 萬以上→10（整數運算，和 Swift 相同）</summary>
    public static long Volume(long tokens)
    {
        if (tokens < VolumeUnit) return 0;
        long bonus = 1, t = tokens / VolumeUnit;
        while (t >= 2 && bonus < MaxVolume)
        {
            t /= 2;
            bonus++;
        }
        return bonus;
    }

    /// <summary>YYYY-MM-DD → 從 1970-01-01 起的日數（days_from_civil）；格式或日期不對時 null</summary>
    public static int? DayNumber(string text)
    {
        if (text.Length != 10 || text[4] != '-' || text[7] != '-') return null;
        for (var i = 0; i < 10; i++)
            if (i != 4 && i != 7 && text[i] is < '0' or > '9') return null;
        int y = int.Parse(text.AsSpan(0, 4)), m = int.Parse(text.AsSpan(5, 2)), d = int.Parse(text.AsSpan(8, 2));
        if (m is < 1 or > 12 || d < 1 || d > DaysIn(y, m)) return null;
        var yy = m <= 2 ? y - 1 : y;
        var era = (yy >= 0 ? yy : yy - 399) / 400;
        var yoe = yy - era * 400;
        var doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    private static int DaysIn(int year, int month) => month switch
    {
        2 => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28,
        4 or 6 or 9 or 11 => 30,
        _ => 31,
    };

    /// <summary>「Lv 7」</summary>
    public string Title => $"Lv {Level}";

    /// <summary>「連續 5 天・最長 12 天」</summary>
    public string StreakText => $"連續 {CurrentStreak} 天・最長 {LongestStreak} 天";

    /// <summary>朗讀程式與滑鼠提示。Windows 只算這台電腦（ADR-0020 第 4 節，2026-10-29 修訂），Mac 的是「所有電腦合併」</summary>
    public string ThisComputerText =>
        $"第 {Level} 級，{(Level == MaxLevel ? "已經是最高級" : $"再 {ToNext} 點升級")}；這台電腦，連續 {CurrentStreak} 天，最長 {LongestStreak} 天";
}
