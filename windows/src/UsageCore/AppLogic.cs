namespace AIUsageMonitor.Core;

/// <summary>畫面上的「現在」（設計 skill 第 8 節）：截圖時固定為 <c>--now</c>，其他時候是系統時間。</summary>
public static class Clock
{
    public static DateTimeOffset? Fixed { get; set; }

    public static DateTimeOffset Now => Fixed ?? DateTimeOffset.Now;
}

/// <summary>
/// 「立即更新」觸發收集器的節流（UsageKit 的 CollectorKickThrottle，FR-50）：60 秒內一次、最近 24 小時最多 100 次。
/// PC 的收集器不上傳額度快照，但每次都會執行 <c>claude -p /usage</c>、<c>codex app-server</c>，同樣限制。
/// </summary>
public sealed class CollectorKickThrottle
{
    public enum Decision { Kick, TooSoon, DailyLimitReached }

    public static readonly TimeSpan MinimumInterval = TimeSpan.FromSeconds(60);
    public const int DailyLimit = 100;
    private static readonly TimeSpan Window = TimeSpan.FromHours(24);

    private readonly List<DateTimeOffset> kicks;

    public CollectorKickThrottle(IEnumerable<DateTimeOffset>? kicks = null) => this.kicks = [.. kicks ?? []];

    /// <summary>最近 24 小時內的觸發時間（由舊到新，最多 100 筆）</summary>
    public IReadOnlyList<DateTimeOffset> Kicks => kicks;

    public Decision DecisionAt(DateTimeOffset now)
    {
        var recent = kicks.Where(k => now - k < Window).ToList();
        // 時鐘倒退（上次觸發在未來）也視為剛觸發過，等時間追上
        if (recent.Count > 0 && now - recent[^1] < MinimumInterval) return Decision.TooSoon;
        if (recent.Count >= DailyLimit) return Decision.DailyLimitReached;
        return Decision.Kick;
    }

    public void Record(DateTimeOffset now)
    {
        kicks.RemoveAll(k => !(now - k < Window && k <= now));
        kicks.Add(now);
        if (kicks.Count > DailyLimit) kicks.RemoveRange(0, kicks.Count - DailyLimit);
    }
}

/// <summary>按下「立即更新」之後頁首下方的說明（Mac 的 RefreshHint）。</summary>
public enum RefreshOutcome { Started, TooSoon, DailyLimitReached, NotInstalled, Failed, Skipped }

public static class RefreshHint
{
    public static string Text(RefreshOutcome outcome) => outcome switch
    {
        RefreshOutcome.Started => "收集器更新中，完成後自動顯示",
        RefreshOutcome.TooSoon => "1 分鐘內已請收集器更新過，完成後自動顯示",
        RefreshOutcome.DailyLimitReached => "24 小時內手動更新已達 100 次，改為每 5 分鐘自動更新",
        RefreshOutcome.NotInstalled => "找不到收集器的排程：在 collector 資料夾執行 windows\\install-task.ps1 -WithQuota",
        RefreshOutcome.Failed => "無法啟動收集器；收集器每 5 分鐘仍會自動更新",
        _ => "資料沒有變化；收集器每 5 分鐘更新一次",
    };

    /// <summary>需要使用者處理的問題用提示色，其他用次要文字色</summary>
    public static bool IsProblem(RefreshOutcome outcome) => outcome is RefreshOutcome.NotInstalled or RefreshOutcome.Failed;
}

/// <summary>
/// 畫圓環需要的值，四捨五入到看得出差別的精度（Mac 的 MenuBarIconContent）：內容相同就不重畫。
/// </summary>
public sealed record RingContent(string Provider, int RemainingPct, int? TimeRemaining, RingState State, string Tooltip, string AccessibilityText)
{
    /// <summary>沒有資料時：灰色虛線的空圓環</summary>
    public static readonly RingContent Empty = new("", 0, null, RingState.Stale, "還沒有額度資料（usage.json）", "還沒有額度資料");

    public static RingContent From(UsageSnapshot? snapshot, WindowChoice choice, DateTimeOffset now)
    {
        if (snapshot?.Window(choice, now) is not { } item) return Empty;
        var content = From(item, snapshot.IsStale(now), now, choice.IsAutomatic);
        // 服務狀態頁的事故（ADR-0018 第 4 節）：顏色以外，螢幕閱讀程式也念得到
        return snapshot.Providers.GetValueOrDefault(item.Provider)?.Incidents?.FirstOrDefault(i => i.IsDisruption) is { } incident
            ? content with { AccessibilityText = $"{content.AccessibilityText}，服務異常：{incident.Name}" }
            : content;
    }

    public static RingContent From(ProviderWindow item, bool stale, DateTimeOffset now, bool isLeast)
    {
        var w = item.Window;
        return new RingContent(
            item.Provider,
            (int)SwiftMath.Round(w.EffectiveRemainingPct(now)),
            w.TimeRemainingFraction(now) is { } t ? (int)SwiftMath.Round(t * 50) * 2 : null,
            RingStates.Of(w, stale, now),
            RingText.Tooltip(item, stale, now),
            RingText.AccessibilityText(item, stale, now, isLeast));
    }
}

/// <summary>螢幕上的矩形（實體像素）。</summary>
public readonly record struct PixelRect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;

    public static PixelRect FromSize(int left, int top, int width, int height) => new(left, top, left + width, top + height);

    public PixelRect Offset(int dx, int dy) => new(Left + dx, Top + dy, Right + dx, Bottom + dy);

    public bool Contains(PixelRect other) =>
        other.Left >= Left && other.Top >= Top && other.Right <= Right && other.Bottom <= Bottom;

    public bool Covers(PixelRect monitor) =>
        Left <= monitor.Left && Top <= monitor.Top && Right >= monitor.Right && Bottom >= monitor.Bottom;

    public int IntersectionArea(PixelRect other)
    {
        var w = Math.Min(Right, other.Right) - Math.Max(Left, other.Left);
        var h = Math.Min(Bottom, other.Bottom) - Math.Max(Top, other.Top);
        return w > 0 && h > 0 ? w * h : 0;
    }
}

/// <summary>一個螢幕：裝置名稱（<c>\\.\DISPLAY1</c>）、整個螢幕與工作區（扣掉工作列）、DPI。</summary>
public sealed record MonitorInfo(string Device, PixelRect Bounds, PixelRect WorkArea, int Dpi, bool IsPrimary = false)
{
    /// <summary>記住位置用的鍵：裝置名稱＋解析度＋DPI（ADR-0015 第 6 節）</summary>
    public string Key => $"{Device}|{Bounds.Width}x{Bounds.Height}|{Dpi}";

    public double Scale => Dpi / 96.0;
}

/// <summary>記住的位置：圓環左上角相對於螢幕左上角的實體像素。</summary>
public sealed record SavedPosition(string Key, int X, int Y, long Used);

/// <summary>懸浮圓環的位置規則（ADR-0015 第 6 節）：貼齊工作區邊緣、每個螢幕記住位置、一律夾進工作區。</summary>
public static class RingPlacement
{
    /// <summary>離邊緣多近時吸過去（DIP）</summary>
    public const double SnapDistance = 16;
    /// <summary>吸過去之後留的邊距（DIP）</summary>
    public const double SnapMargin = 8;
    /// <summary>沒有記錄時，主螢幕工作區右下角內縮（DIP）</summary>
    public const double DefaultInset = 24;
    public const int MaxSavedPositions = 16;

    /// <summary>放開時：距離工作區邊緣 ≤ 16 DIP 就吸到那一邊（留 8 DIP），角落可同時吸兩邊；最後夾進工作區。</summary>
    public static PixelRect Snap(PixelRect ring, MonitorInfo monitor)
    {
        var work = monitor.WorkArea;
        var snap = (int)Math.Round(SnapDistance * monitor.Scale);
        var margin = (int)Math.Round(SnapMargin * monitor.Scale);
        var x = ring.Left;
        var y = ring.Top;
        if (ring.Left - work.Left <= snap) x = work.Left + margin;
        else if (work.Right - ring.Right <= snap) x = work.Right - margin - ring.Width;
        if (ring.Top - work.Top <= snap) y = work.Top + margin;
        else if (work.Bottom - ring.Bottom <= snap) y = work.Bottom - margin - ring.Height;
        return Clamp(PixelRect.FromSize(x, y, ring.Width, ring.Height), work);
    }

    /// <summary>整個圓環放進工作區（比工作區大時對齊左上）。</summary>
    public static PixelRect Clamp(PixelRect ring, PixelRect work)
    {
        var x = Math.Max(work.Left, Math.Min(ring.Left, work.Right - ring.Width));
        var y = Math.Max(work.Top, Math.Min(ring.Top, work.Bottom - ring.Height));
        return PixelRect.FromSize(x, y, ring.Width, ring.Height);
    }

    /// <summary>
    /// 啟動或顯示設定改變時：找相同的鍵 → 同裝置名稱（依解析度比例換算）→ 主螢幕工作區右下角；最後夾進那個螢幕的工作區。
    /// <paramref name="size"/> 是圓環在該螢幕上的實體像素邊長。
    /// </summary>
    public static (PixelRect Rect, MonitorInfo Monitor) Restore(IReadOnlyList<SavedPosition> saved, IReadOnlyList<MonitorInfo> monitors,
                                                                Func<MonitorInfo, int> size)
    {
        if (monitors.Count == 0) throw new ArgumentException("沒有螢幕", nameof(monitors));
        // 最近用過的優先
        foreach (var position in saved.OrderByDescending(p => p.Used))
        {
            var monitor = monitors.FirstOrDefault(m => m.Key == position.Key);
            if (monitor is null) continue;
            var s = size(monitor);
            return (Clamp(PixelRect.FromSize(monitor.Bounds.Left + position.X, monitor.Bounds.Top + position.Y, s, s), monitor.WorkArea), monitor);
        }
        foreach (var position in saved.OrderByDescending(p => p.Used))
        {
            var device = position.Key.Split('|')[0];
            var monitor = monitors.FirstOrDefault(m => m.Device == device);
            if (monitor is null || ParseSize(position.Key) is not var (w, h)) continue;
            var s = size(monitor);
            var x = (int)Math.Round((double)position.X * monitor.Bounds.Width / w);
            var y = (int)Math.Round((double)position.Y * monitor.Bounds.Height / h);
            return (Clamp(PixelRect.FromSize(monitor.Bounds.Left + x, monitor.Bounds.Top + y, s, s), monitor.WorkArea), monitor);
        }
        var primary = monitors.FirstOrDefault(m => m.IsPrimary) ?? monitors[0];
        var side = size(primary);
        var inset = (int)Math.Round(DefaultInset * primary.Scale);
        var rect = PixelRect.FromSize(primary.WorkArea.Right - inset - side, primary.WorkArea.Bottom - inset - side, side, side);
        return (Clamp(rect, primary.WorkArea), primary);
    }

    /// <summary>記下圓環在這個螢幕的位置；同一個鍵取代，最多 16 筆（最久沒用的先刪）。</summary>
    public static List<SavedPosition> Remember(IEnumerable<SavedPosition> saved, PixelRect ring, MonitorInfo monitor, DateTimeOffset now)
    {
        var list = saved.Where(p => p.Key != monitor.Key).ToList();
        list.Add(new SavedPosition(monitor.Key, ring.Left - monitor.Bounds.Left, ring.Top - monitor.Bounds.Top, now.ToUnixTimeSeconds()));
        return [.. list.OrderByDescending(p => p.Used).Take(MaxSavedPositions)];
    }

    /// <summary>圓環所在的螢幕：與圓環重疊最多的，沒有重疊時用主螢幕。</summary>
    public static MonitorInfo MonitorOf(PixelRect ring, IReadOnlyList<MonitorInfo> monitors)
    {
        var best = monitors.OrderByDescending(m => m.Bounds.IntersectionArea(ring)).First();
        return best.Bounds.IntersectionArea(ring) > 0 ? best : monitors.FirstOrDefault(m => m.IsPrimary) ?? monitors[0];
    }

    private static (int, int)? ParseSize(string key)
    {
        var parts = key.Split('|');
        if (parts.Length < 2) return null;
        var size = parts[1].Split('x');
        return size.Length == 2 && int.TryParse(size[0], out var w) && int.TryParse(size[1], out var h) && w > 0 && h > 0 ? (w, h) : null;
    }
}

/// <summary>面板的位置（ADR-0015 第 6 節）：貼著圓環、間距 8 DIP，優先放在圓環內側；第一個完全在工作區內的候選採用。</summary>
public static class PanelPlacement
{
    public const double Gap = 8;
    /// <summary>從系統匣打開時，離工作區角落的距離（DIP）</summary>
    public const double TrayInset = 12;

    public static PixelRect NextToRing(PixelRect ring, int width, int height, MonitorInfo monitor)
    {
        var work = monitor.WorkArea;
        var gap = (int)Math.Round(Gap * monitor.Scale);
        var ringCenterX = (ring.Left + ring.Right) / 2;
        var ringCenterY = (ring.Top + ring.Bottom) / 2;
        var workCenterX = (work.Left + work.Right) / 2;
        var workCenterY = (work.Top + work.Bottom) / 2;
        // 圓環在右半邊時面板放左邊，在下半邊時面板往上對齊
        var leftFirst = ringCenterX >= workCenterX;
        var top = ringCenterY >= workCenterY ? ring.Bottom - height : ring.Top;
        var left = ringCenterX >= workCenterX ? ring.Right - width : ring.Left;
        var candidates = new List<PixelRect>();
        var beside = new[] { PixelRect.FromSize(ring.Left - gap - width, top, width, height), PixelRect.FromSize(ring.Right + gap, top, width, height) };
        candidates.AddRange(leftFirst ? beside : beside.Reverse());
        var vertical = new[] { PixelRect.FromSize(left, ring.Top - gap - height, width, height), PixelRect.FromSize(left, ring.Bottom + gap, width, height) };
        candidates.AddRange(ringCenterY >= workCenterY ? vertical : vertical.Reverse());
        foreach (var c in candidates)
        {
            if (work.Contains(c)) return c;
        }
        return RingPlacement.Clamp(candidates[0], work);
    }

    /// <summary>從系統匣打開：放在離滑鼠最近的工作區角落（工作列可能在上、下、左、右）。</summary>
    public static PixelRect NearTray(int cursorX, int cursorY, int width, int height, MonitorInfo monitor)
    {
        var work = monitor.WorkArea;
        var inset = (int)Math.Round(TrayInset * monitor.Scale);
        var x = cursorX >= (work.Left + work.Right) / 2 ? work.Right - inset - width : work.Left + inset;
        var y = cursorY >= (work.Top + work.Bottom) / 2 ? work.Bottom - inset - height : work.Top + inset;
        return RingPlacement.Clamp(PixelRect.FromSize(x, y, width, height), work);
    }
}

/// <summary>前景視窗是不是「全螢幕」（ADR-0015 第 6 節）：取得視窗資訊在 App 裡，判斷規則在這裡測試。</summary>
public static class FullscreenRule
{
    /// <summary>桌面、工作列與系統的殼層視窗：它們涵蓋整個螢幕但不是全螢幕的 App</summary>
    public static readonly IReadOnlySet<string> ShellClasses = new HashSet<string>(StringComparer.Ordinal)
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow",
    };

    /// <param name="className">前景視窗的類別名稱</param>
    /// <param name="cloaked">DWM 隱藏中（其他虛擬桌面、UWP 尚未顯示）</param>
    /// <param name="bounds">前景視窗的矩形（DWMWA_EXTENDED_FRAME_BOUNDS）</param>
    /// <param name="foregroundMonitor">前景視窗所在的螢幕</param>
    /// <param name="ringMonitor">圓環所在的螢幕：只有同一個螢幕的全螢幕才隱藏</param>
    /// <param name="maximizedWithCaption">有標題列的最大化視窗：工作列自動隱藏時它也涵蓋整個螢幕，但不是全螢幕
    /// （瀏覽器按 F11、遊戲、影片是沒有標題列的視窗，不受影響）</param>
    public static bool IsFullscreen(string className, bool cloaked, PixelRect bounds, MonitorInfo foregroundMonitor, MonitorInfo ringMonitor,
                                    bool maximizedWithCaption = false)
    {
        if (cloaked || maximizedWithCaption || ShellClasses.Contains(className)) return false;
        if (foregroundMonitor.Device != ringMonitor.Device) return false;
        return bounds.Covers(foregroundMonitor.Bounds);
    }

    /// <summary>
    /// SHQueryUserNotificationState：3＝獨占全螢幕的 D3D、4＝簡報模式（全系統的狀態，呼叫端只在前景視窗位於圓環的螢幕時採信）。
    /// 2（QUNS_BUSY）連一般的全螢幕視窗都會回報、無法分辨螢幕，不用。
    /// </summary>
    public static bool IsExclusiveFullscreen(int notificationState) => notificationState is 3 or 4;
}
