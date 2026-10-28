using System;
using System.Windows;
using System.Windows.Media;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 雙圓環（Mac 選單列圖示與面板的 DualRing，設計 skill 第 9 節）：外圈＝剩餘 %，內圈＝距離重置的剩餘時間比例。
/// 四種狀態不只靠顏色：太快＝右上角提示色小點；剩 &lt; 20%＝外圈轉紅；過期＝整個轉灰且外圈改為虛線。
/// 系統匣圖示與面板共用；懸浮圓環見 RingFace.cs。
/// </summary>
internal static class RingDrawing
{
    /// <summary>系統匣圖示（16 單位的畫布，同 Mac 選單列圖示的比例：外圈半徑 6.6、寬 2.4，內圈 3.2、寬 1.8）</summary>
    public static void DrawTray(DrawingContext dc, RingContent c, double size, Palette p)
    {
        var k = size / 16;
        var center = new Point(8 * k, 8 * k);
        var main = p.BarColor(c.Provider, c.State);
        Arc(dc, center, 6.6 * k, 2.4 * k, c.Provider.Length == 0 ? 0 : c.RemainingPct / 100.0, main,
            Palette.Brush(p.Primary.Color, p.Dark ? 0.28 : 0.22).Color, c.State == RingState.Stale);
        if (c.TimeRemaining is { } t)
        {
            Arc(dc, center, 3.0 * k, 1.8 * k, t / 100.0, p.Secondary.Color, Palette.Brush(p.Primary.Color, 0.12).Color, false);
        }
        if (c.State == RingState.TooFast)
        {
            dc.DrawEllipse(p.Notice, null, new Point(13.6 * k, 2.6 * k), 2.4 * k, 2.4 * k);
        }
        AgentOverlay.DrawTray(dc, c.Agent, k, p);
    }

    /// <summary>外圈＋內圈（面板主圓環也用這個）。<paramref name="appear"/> 是打開面板時描繪的進度 0…1</summary>
    public static void DrawDual(DrawingContext dc, RingContent c, Point center, double radius, double lineWidth, Palette p, double appear)
    {
        var main = p.BarColor(c.Provider, c.State);
        var empty = c.Provider.Length == 0;
        Arc(dc, center, radius, lineWidth, empty ? 0 : c.RemainingPct / 100.0 * appear, main,
            empty ? Palette.Brush(p.StaleColor, 0.35).Color : Palette.Brush(main, 0.18).Color, c.State == RingState.Stale);
        if (c.TimeRemaining is { } t)
        {
            var inner = lineWidth * 0.55;
            var secondary = c.State == RingState.Stale ? p.Tertiary.Color : p.Secondary.Color;
            Arc(dc, center, radius - lineWidth * 1.6, inner, t / 100.0 * appear, secondary, Palette.Brush(p.Secondary.Color, 0.15).Color, false);
        }
    }

    /// <summary>從 12 點鐘方向順時針畫 <paramref name="fraction"/> 的弧，底下是淡色軌道；<paramref name="dashed"/> 時兩者都是虛線</summary>
    public static void Arc(DrawingContext dc, Point center, double radius, double width, double fraction, Color color, Color track, bool dashed) =>
        Arc(dc, center, radius, width, fraction, new SolidColorBrush(color), track, dashed);

    public static void Arc(DrawingContext dc, Point center, double radius, double width, double fraction, Brush color, Color track, bool dashed)
    {
        // 虛線約 16 段：小圖示上也看得出斷開
        DashStyle? dash = null;
        if (dashed)
        {
            var segment = 2 * Math.PI * radius / 16 / width;
            dash = new DashStyle([segment * 0.55, segment * 0.45], 0);
            dash.Freeze();
        }
        if (track.A > 0)
        {
            var trackPen = new Pen(new SolidColorBrush(track), width) { DashStyle = dash ?? DashStyles.Solid };
            dc.DrawEllipse(null, trackPen, center, radius, radius);
        }
        var clamped = Math.Clamp(fraction, 0, 1);
        if (clamped <= 0) return;
        var pen = new Pen(color, width)
        {
            DashStyle = dash ?? DashStyles.Solid,
            StartLineCap = dashed ? PenLineCap.Flat : PenLineCap.Round,
            EndLineCap = dashed ? PenLineCap.Flat : PenLineCap.Round,
            DashCap = PenLineCap.Flat,
        };
        if (clamped >= 0.9999)
        {
            dc.DrawEllipse(null, pen, center, radius, radius);
            return;
        }
        var angle = 2 * Math.PI * clamped;
        var start = new Point(center.X, center.Y - radius);
        var end = new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle));
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            ctx.BeginFigure(start, false, false);
            ctx.ArcTo(end, new Size(radius, radius), 0, clamped > 0.5, SweepDirection.Clockwise, true, false);
        }
        geometry.Freeze();
        dc.DrawGeometry(null, pen, geometry);
    }
}

/// <summary>原創的服務圖示（設計 skill 第 2 節，viewBox 0 0 24 24）：Claude 八芒星、Codex 六瓣圓雲（中間鏤空 >_）。</summary>
internal static class ProviderIcons
{
    public static readonly Geometry Claude = CreateClaude();
    public static readonly Geometry Codex = CreateCodex();
    public static readonly Geometry Other = Frozen(new EllipseGeometry(new Point(12, 12), 9, 9));

    public static Geometry For(string key) => key switch
    {
        "claude" => Claude,
        "codex" => Codex,
        _ => Other,
    };

    private static Geometry CreateClaude()
    {
        var star = Geometry.Parse("M12.00 1.00 L13.65 8.03 L17.80 6.20 L15.97 10.35 L23.00 12.00 L15.97 13.65 L17.80 17.80 L13.65 15.97 " +
                                  "L12.00 23.00 L10.35 15.97 L6.20 17.80 L8.03 13.65 L1.00 12.00 L8.03 10.35 L6.20 6.20 L10.35 8.03Z");
        // 實心＋0.7 寬、圓角接合的同色描邊
        var outline = star.GetWidenedPathGeometry(new Pen(Brushes.Black, 0.7) { LineJoin = PenLineJoin.Round });
        return Frozen(Geometry.Combine(star, outline, GeometryCombineMode.Union, null));
    }

    private static Geometry CreateCodex()
    {
        Geometry cloud = new EllipseGeometry(new Point(12, 12), 8, 8);
        foreach (var (x, y) in new[] { (12.00, 5.00), (18.06, 8.50), (18.06, 15.50), (12.00, 19.00), (5.94, 15.50), (5.94, 8.50) })
        {
            cloud = Geometry.Combine(cloud, new EllipseGeometry(new Point(x, y), 4, 4), GeometryCombineMode.Union, null);
        }
        var prompt = Geometry.Parse("M8 9 l3 3 -3 3 M12.6 15.2 h3.8")
            .GetWidenedPathGeometry(new Pen(Brushes.Black, 2.3) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round });
        // 鏤空處透出背景（不是畫上背景色）
        return Frozen(Geometry.Combine(cloud, prompt, GeometryCombineMode.Exclude, null));
    }

    private static Geometry Frozen(Geometry g)
    {
        g.Freeze();
        return g;
    }
}

/// <summary>服務圖示（以 <see cref="Fill"/> 填色）</summary>
internal sealed class ProviderIconElement : FrameworkElement
{
    private readonly Geometry geometry;
    private readonly Brush fill;

    public ProviderIconElement(string provider, Brush fill, double size)
    {
        geometry = ProviderIcons.For(provider);
        this.fill = fill;
        Width = Height = size;
        AutomationProperties.SetName(this, ProviderInfo.DisplayName(provider));
    }

    public Brush Fill => fill;

    protected override void OnRender(DrawingContext dc)
    {
        dc.PushTransform(new ScaleTransform(ActualWidth / 24, ActualHeight / 24));
        dc.DrawGeometry(fill, null, geometry);
        dc.Pop();
    }
}

internal static class AutomationProperties
{
    public static void SetName(DependencyObject element, string name) => System.Windows.Automation.AutomationProperties.SetName(element, name);
}

/// <summary>面板的主圓環（84 DIP、線寬 9）。<see cref="Appear"/> 由面板的動畫驅動。</summary>
internal sealed class DualRingElement : FrameworkElement
{
    private readonly RingContent content;
    private readonly Palette palette;
    private double appear = 1;

    public DualRingElement(RingContent content, Palette palette, double size = 84)
    {
        this.content = content;
        this.palette = palette;
        Width = Height = size;
    }

    public double Appear
    {
        get => appear;
        set
        {
            appear = value;
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        const double lineWidth = 9;
        var size = Math.Min(ActualWidth, ActualHeight);
        RingDrawing.DrawDual(dc, content, new Point(size / 2, size / 2), size / 2 - lineWidth / 2, lineWidth, palette, appear);
    }
}

/// <summary>額度的進度條（高 7，膠囊形），上面有預期進度標記（照時間比例應剩多少；比標記短＝用得比預期快）。</summary>
internal sealed class QuotaBarElement : FrameworkElement
{
    private readonly double fraction;
    private readonly double? expected;
    private readonly Color tint;
    private readonly Palette palette;
    private double appear = 1;
    private double markerOpacity = 1;

    public QuotaBarElement(double fraction, double? expected, Color tint, Palette palette)
    {
        this.fraction = fraction;
        this.expected = expected;
        this.tint = tint;
        this.palette = palette;
        Height = 13;
        if (expected is { } e)
        {
            var help = UsageWindow.ExpectedDescription(e * 100);
            ToolTip = help;
            System.Windows.Automation.AutomationProperties.SetHelpText(this, help);
        }
    }

    public double Appear
    {
        get => appear;
        set
        {
            appear = value;
            InvalidateVisual();
        }
    }

    public double MarkerOpacity
    {
        get => markerOpacity;
        set
        {
            markerOpacity = value;
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        const double barHeight = 7;
        var top = (ActualHeight - barHeight) / 2;
        var width = ActualWidth;
        // 透明的整條區域：滑鼠移到進度條任何地方都有預期進度的說明
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, width, ActualHeight));
        dc.DrawRoundedRectangle(Palette.Brush(palette.Primary.Color, palette.Dark ? 0.14 : 0.1), null,
                                new Rect(0, top, width, barHeight), barHeight / 2, barHeight / 2);
        var filled = width * Math.Clamp(fraction * appear, 0, 1);
        if (filled > 0)
        {
            dc.DrawRoundedRectangle(new SolidColorBrush(tint), null, new Rect(0, top, Math.Max(filled, barHeight), barHeight), barHeight / 2, barHeight / 2);
        }
        if (expected is { } e && markerOpacity > 0)
        {
            var x = width * Math.Clamp(e, 0, 1);
            dc.PushOpacity(markerOpacity);
            dc.DrawRoundedRectangle(palette.Primary, null, new Rect(x - 1.25, 0, 2.5, ActualHeight), 1, 1);
            dc.Pop();
        }
    }
}
