namespace AIUsageMonitor.Core;

/// <summary>滑鼠移上去時膠囊往哪邊展開（ADR-0015「懸浮圓環設計」）：永遠朝畫面內側。</summary>
public enum RingExpandDirection { Left, Right, Down, Up }

/// <summary>圓環貼在工作區的哪一個左右邊緣（貼邊收合與往下展開用）。</summary>
public enum RingDock { None, Left, Right }

/// <summary>以圓環中心為原點的矩形（DIP）。</summary>
public readonly record struct DipRect(double Left, double Top, double Right, double Bottom)
{
    public double Width => Right - Left;
    public double Height => Bottom - Top;

    public DipRect Inflate(double d) => new(Left - d, Top - d, Right + d, Bottom + d);

    public DipRect MirrorX() => new(-Right, Top, -Left, Bottom);

    public DipRect MirrorY() => new(Left, -Bottom, Right, -Top);
}

/// <summary>
/// 懸浮圓環與展開膠囊的尺寸（DIP，以圓環中心為原點）。畫面（WPF）與位置計算共用，畫面不自己算尺寸。
/// 視窗比圓環的玻璃圓底大 <see cref="Inset"/>（留給陰影），所以圓底半徑是視窗邊長的一半減 <see cref="Inset"/>。
/// </summary>
public static class RingShape
{
    /// <summary>玻璃圓底與視窗邊緣的距離（陰影）</summary>
    public const double Inset = 3;
    /// <summary>右邊兩行資訊的寬度</summary>
    public const double InfoWidth = 176;
    /// <summary>兩行資訊的高度（每行：名稱與 %、細進度條與倒數）</summary>
    public const double RowsHeight = 64;
    /// <summary>圓環與資訊之間</summary>
    public const double Gap = 10;
    /// <summary>資訊到膠囊末端</summary>
    public const double EndPad = 14;
    /// <summary>往下展開時外框比圓底多出的距離（外框的圓角與圓底同心）</summary>
    public const double FramePad = 6;
    /// <summary>往下展開時外框其他三個角的圓角</summary>
    public const double FrameCorner = 18;

    public static double DiscRadius(double ringDip) => ringDip / 2 - Inset;

    /// <summary>左右展開的膠囊高度：放得下圓底與兩行資訊，兩端是與圓環同心的半圓</summary>
    public static double CapsuleHeight(double ringDip) => Math.Max(2 * DiscRadius(ringDip) + 2 * FramePad, RowsHeight + 16);

    /// <summary>往下展開的外框寬度</summary>
    public static double FrameWidth(double ringDip) => Math.Max(InfoWidth + 24, 2 * (DiscRadius(ringDip) + FramePad));

    /// <summary>展開後的外框（不含陰影）。<paramref name="dock"/> 只影響往上下展開時圓環靠哪一邊（貼右邊時圓環在右上）</summary>
    public static DipRect Shape(RingExpandDirection direction, RingDock dock, double ringDip)
    {
        var r = DiscRadius(ringDip);
        switch (direction)
        {
            case RingExpandDirection.Right:
            case RingExpandDirection.Left:
            {
                var half = CapsuleHeight(ringDip) / 2;
                var right = new DipRect(-half, -half, r + Gap + InfoWidth + EndPad, half);
                return direction == RingExpandDirection.Right ? right : right.MirrorX();
            }
            default:
            {
                var edge = r + FramePad;
                var down = new DipRect(-edge, -edge, -edge + FrameWidth(ringDip), r + Gap + RowsHeight + 10);
                if (dock == RingDock.Right) down = down.MirrorX();
                return direction == RingExpandDirection.Down ? down : down.MirrorY();
            }
        }
    }

    /// <summary>
    /// 角色樣式展開後角色的中心（以圓環中心為原點的 x；ADR-0015 第 6 節、G1）：一律在膠囊左端的半圓。往右展開就是圓環本身；
    /// 往左展開在膠囊左端，角色從圓環連續移過去
    /// </summary>
    public static double MascotSlot(RingExpandDirection direction, double ringDip) =>
        direction == RingExpandDirection.Left ? Shape(direction, RingDock.None, ringDip).Left + CapsuleHeight(ringDip) / 2 : 0;

    /// <summary>角色樣式的兩行資訊：角色右邊、垂直置中</summary>
    public static DipRect MascotInfo(RingExpandDirection direction, double ringDip)
    {
        var left = MascotSlot(direction, ringDip) + DiscRadius(ringDip) + Gap;
        return new DipRect(left, -RowsHeight / 2, left + InfoWidth, RowsHeight / 2);
    }

    /// <summary>兩行資訊的位置</summary>
    public static DipRect Info(RingExpandDirection direction, RingDock dock, double ringDip)
    {
        var r = DiscRadius(ringDip);
        switch (direction)
        {
            case RingExpandDirection.Right:
            case RingExpandDirection.Left:
            {
                var right = new DipRect(r + Gap, -RowsHeight / 2, r + Gap + InfoWidth, RowsHeight / 2);
                return direction == RingExpandDirection.Right ? right : right.MirrorX();
            }
            default:
            {
                var shape = Shape(RingExpandDirection.Down, dock, ringDip);
                var left = (shape.Left + shape.Right - InfoWidth) / 2;
                var down = new DipRect(left, r + Gap, left + InfoWidth, r + Gap + RowsHeight);
                return direction == RingExpandDirection.Down ? down : down.MirrorY();
            }
        }
    }
}

/// <summary>
/// 懸浮圓環展開與貼邊收合的位置規則（實體像素）：展開方向朝畫面內側、展開後不超出目前螢幕的工作區、
/// 貼在左右邊緣時縮成半圓的小標籤。
/// </summary>
public static class RingFloatLayout
{
    /// <summary>圓環貼在左右邊緣（放開時吸過去的距離以內）</summary>
    public static RingDock DockOf(PixelRect ring, MonitorInfo monitor)
    {
        var work = monitor.WorkArea;
        var near = (int)Math.Round(RingPlacement.SnapDistance * monitor.Scale);
        if (ring.Left - work.Left <= near) return RingDock.Left;
        if (work.Right - ring.Right <= near) return RingDock.Right;
        return RingDock.None;
    }

    /// <summary>
    /// 貼在左右邊緣時往下展開（下面放不下就往上）；其他位置在螢幕右半邊往左、左半邊往右。
    /// <paramref name="capsule"/>（角色樣式）：貼邊時也是膠囊，朝畫面內側左右展開（角色在左、兩行在右，不留空白）
    /// </summary>
    public static RingExpandDirection Direction(PixelRect ring, MonitorInfo monitor, double ringDip, bool capsule = false)
    {
        var dock = DockOf(ring, monitor);
        var work = monitor.WorkArea;
        if (dock != RingDock.None && capsule) return dock == RingDock.Left ? RingExpandDirection.Right : RingExpandDirection.Left;
        if (dock != RingDock.None)
        {
            var below = RingShape.Shape(RingExpandDirection.Down, dock, ringDip).Inflate(RingShape.Inset).Bottom * monitor.Scale;
            var centerY = ring.Top + ring.Height / 2.0;
            return centerY + below <= work.Bottom ? RingExpandDirection.Down : RingExpandDirection.Up;
        }
        var centerX = ring.Left + ring.Width / 2.0;
        return centerX >= (work.Left + work.Right) / 2.0 ? RingExpandDirection.Left : RingExpandDirection.Right;
    }

    /// <summary>以圓環中心為原點的矩形換成螢幕上的實體像素</summary>
    public static PixelRect ToPixels(PixelRect ring, DipRect rect, double scale)
    {
        var cx = ring.Left + ring.Width / 2.0;
        var cy = ring.Top + ring.Height / 2.0;
        var left = (int)Math.Floor(cx + rect.Left * scale);
        var top = (int)Math.Floor(cy + rect.Top * scale);
        return new PixelRect(left, top, (int)Math.Ceiling(cx + rect.Right * scale), (int)Math.Ceiling(cy + rect.Bottom * scale));
    }

    /// <summary>展開後的視窗被推回工作區時移動了多少（實體像素）：畫的時候展開的內容要跟著移，否則會被視窗裁掉</summary>
    public static (int Dx, int Dy) ExpandedShift(PixelRect ring, RingExpandDirection direction, MonitorInfo monitor, double ringDip)
    {
        var shape = RingShape.Shape(direction, DockOf(ring, monitor), ringDip).Inflate(RingShape.Inset);
        var raw = ToPixels(ring, shape, monitor.Scale);
        var clamped = Clamp(raw, monitor.WorkArea);
        return (clamped.Left - raw.Left, clamped.Top - raw.Top);
    }

    /// <summary>展開後的視窗（含陰影），推回工作區內（比工作區大時對齊左上）</summary>
    public static PixelRect Expanded(PixelRect ring, RingExpandDirection direction, MonitorInfo monitor, double ringDip)
    {
        var shape = RingShape.Shape(direction, DockOf(ring, monitor), ringDip).Inflate(RingShape.Inset);
        var rect = ToPixels(ring, shape, monitor.Scale);
        return Clamp(rect, monitor.WorkArea);
    }

    /// <summary>貼邊收合時的小標籤：圓環移到工作區邊緣、只露出一半（視窗只涵蓋露出的那一半）</summary>
    public static PixelRect Tab(PixelRect ring, RingDock dock, MonitorInfo monitor)
    {
        var work = monitor.WorkArea;
        var half = (int)Math.Ceiling(ring.Width / 2.0);
        return dock switch
        {
            RingDock.Left => new PixelRect(work.Left, ring.Top, work.Left + half, ring.Bottom),
            RingDock.Right => new PixelRect(work.Right - half, ring.Top, work.Right, ring.Bottom),
            _ => ring,
        };
    }

    /// <summary>兩個矩形的聯集（展開或滑出的過程用一個視窗涵蓋全部，過程中不改視窗大小）</summary>
    public static PixelRect Union(PixelRect a, PixelRect b) =>
        new(Math.Min(a.Left, b.Left), Math.Min(a.Top, b.Top), Math.Max(a.Right, b.Right), Math.Max(a.Bottom, b.Bottom));

    private static PixelRect Clamp(PixelRect rect, PixelRect work)
    {
        var x = Math.Max(work.Left, Math.Min(rect.Left, work.Right - rect.Width));
        var y = Math.Max(work.Top, Math.Min(rect.Top, work.Bottom - rect.Height));
        return PixelRect.FromSize(x, y, rect.Width, rect.Height);
    }
}

/// <summary>
/// 展開後的一行：服務、額度名稱、剩餘 %、細進度條、重置倒數，必要時「用得較快」。
/// 會在重置前用完時（ADR-0018 第 3 節）倒數換成預測（<paramref name="Forecast"/>，不到 60 分鐘 <paramref name="Urgent"/>）。
/// </summary>
public sealed record RingDetailRow(string Provider, string Name, int RemainingPct, double Fraction, string Countdown, RingState State,
                                   string? Forecast = null, bool Urgent = false)
{
    public bool TooFast => State == RingState.TooFast;
}

/// <summary>
/// 展開膠囊的兩行（FR-26 的延伸）：第一行是圓環顯示的額度（自動＝剩最少的），第二行是另一個服務最吃緊的額度；
/// 只有一個服務時第二行是同一個服務的另一個額度。內容相同就不重畫。
/// </summary>
public sealed record RingDetails(IReadOnlyList<RingDetailRow> Rows)
{
    public static readonly RingDetails Empty = new([]);

    public static RingDetails From(UsageSnapshot? snapshot, WindowChoice choice, DateTimeOffset now)
    {
        if (snapshot?.Window(choice, now) is not { } first) return Empty;
        var stale = snapshot.IsStale(now);
        var rows = new List<RingDetailRow> { Row(first, stale, now) };
        ProviderWindow? second = null;
        foreach (var key in snapshot.OrderedProviderKeys.Where(k => k != first.Provider))
        {
            if (snapshot.Providers[key] is not { Error: null } usage) continue;
            foreach (var w in usage.VisibleWindows)
            {
                var candidate = new ProviderWindow(key, w);
                if (second is null || Tighter(candidate, second, now)) second = candidate;
            }
        }
        if (second is null && snapshot.Providers.TryGetValue(first.Provider, out var same) && same.Error is null)
        {
            foreach (var w in same.VisibleWindows.Where(w => w.Id != first.Window.Id))
            {
                var candidate = new ProviderWindow(first.Provider, w);
                if (second is null || Tighter(candidate, second, now)) second = candidate;
            }
        }
        if (second is not null) rows.Add(Row(second, stale, now));
        return new RingDetails(rows);
    }

    public bool Equals(RingDetails? other) => other is not null && Rows.SequenceEqual(other.Rows);

    public override int GetHashCode() => Rows.Aggregate(0, (h, r) => HashCode.Combine(h, r));

    private static RingDetailRow Row(ProviderWindow item, bool stale, DateTimeOffset now)
    {
        var w = item.Window;
        var remaining = (int)SwiftMath.Round(w.EffectiveRemainingPct(now));
        var countdown = w.IsReset(now) ? "已重置"
            : w.ResetsAt is { } r && ResetCountdown.Text(r, now) is { } text ? $"{text}後重置" : "";
        var forecast = QuotaForecast.Current(w, stale, now);
        return new RingDetailRow(item.Provider, item.DisplayName, remaining, remaining / 100.0, countdown, RingStates.Of(w, stale, now),
                                 forecast?.ShortLine(now), forecast?.Urgent ?? false);
    }

    // 同 TightestWindow：剩餘較少；同分時較早重置的
    private static bool Tighter(ProviderWindow a, ProviderWindow b, DateTimeOffset now)
    {
        var ra = a.Window.EffectiveRemainingPct(now);
        var rb = b.Window.EffectiveRemainingPct(now);
        if (ra != rb) return ra < rb;
        return (a.Window.ResetsAt ?? DateTimeOffset.MaxValue) < (b.Window.ResetsAt ?? DateTimeOffset.MaxValue);
    }
}
