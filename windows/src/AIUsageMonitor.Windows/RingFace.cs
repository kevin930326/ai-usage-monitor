using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>畫圓環面（玻璃底之上的部分）需要的選項。</summary>
internal readonly record struct RingFaceOptions(bool Ticks, double PixelsPerDip);

/// <summary>
/// 圓環的「圖示樣式」（ADR-0015「懸浮圓環設計」）：玻璃底之上要畫什麼。展開、貼邊、方向與動畫在 <see cref="RingWindow"/>，
/// 之後換成角色（design/mascot/MASCOT-SPEC.md）時只要另寫一個實作，不必改那些邏輯。
/// </summary>
internal interface IRingFace
{
    /// <summary>完整的圓環面：<paramref name="radius"/> 是玻璃圓底的半徑</summary>
    void Draw(DrawingContext dc, RingContent content, Point center, double radius, Palette palette, RingFaceOptions options);

    /// <summary>貼邊收合的小標籤：只露出 <paramref name="visible"/> 這一半（圖示與 %）</summary>
    void DrawTab(DrawingContext dc, RingContent content, Point center, double radius, Rect visible, Palette palette, RingFaceOptions options);
}

/// <summary>
/// 預設的圓環面（C2）：外圈剩餘額度（細線、圓頭、淡漸層、末端白色小圓點）、內圈距離重置（更細）、
/// 中間上方服務圖示、下方剩餘 %（% 縮小變淡）。用得太快＝右上角橘色徽章點（白邊）；剩不到 20%＝紅色帶一點柔光；
/// 過期＝灰色虛線＋「過期」；可選的 60 格刻度表示這個額度週期過了多少時間。
/// </summary>
internal sealed class GlassRingFace : IRingFace
{
    public static readonly GlassRingFace Shared = new();

    public void Draw(DrawingContext dc, RingContent c, Point center, double radius, Palette p, RingFaceOptions o)
    {
        var empty = c.Provider.Length == 0;
        var stale = c.State == RingState.Stale;
        var main = p.BarColor(c.Provider, c.State);
        var width = Math.Max(2.2, radius * 0.12);
        var tickBand = o.Ticks ? Math.Max(2.5, radius * 0.11) : 0;
        var outer = radius - 2.5 - tickBand - width / 2;
        if (o.Ticks) DrawTicks(dc, c, center, radius - 1.5, tickBand, p);

        var fraction = empty ? 0 : c.RemainingPct / 100.0;
        if (c.State == RingState.Critical && fraction > 0)
        {
            // 一點柔光：同一段弧，寬、淡
            RingDrawing.Arc(dc, center, outer, width * 2.6, fraction, Color.FromArgb(0x30, main.R, main.G, main.B), Colors.Transparent, false);
        }
        var track = empty || stale ? Palette.Brush(p.StaleColor, 0.35).Color : Color.FromArgb((byte)(p.Dark ? 0x38 : 0x2E), main.R, main.G, main.B);
        var gradient = stale ? (Brush)new SolidColorBrush(main) : Gradient(main, p.Dark);
        RingDrawing.Arc(dc, center, outer, width, fraction, gradient, track, stale);
        if (!stale && fraction is > 0 and < 0.9999)
        {
            var angle = 2 * Math.PI * fraction;
            var end = new Point(center.X + outer * Math.Sin(angle), center.Y - outer * Math.Cos(angle));
            dc.DrawEllipse(Palette.Brush(Colors.Black, 0.18), null, new Point(end.X, end.Y + 0.4), width * 0.42, width * 0.42);
            dc.DrawEllipse(Brushes.White, null, end, width * 0.34, width * 0.34);
        }
        if (c.TimeRemaining is { } t)
        {
            var inner = width * 0.55;
            var innerRadius = outer - width / 2 - 1.6 - inner / 2;
            var secondary = stale ? p.Tertiary.Color : p.Secondary.Color;
            RingDrawing.Arc(dc, center, innerRadius, inner, t / 100.0, new SolidColorBrush(secondary), Palette.Brush(p.Secondary.Color, 0.14).Color, false);
        }

        // 中間：上方服務圖示、下方剩餘 %
        var contentRadius = outer - width * 1.8;
        var icon = Math.Max(8, contentRadius * 0.78);
        var number = Math.Max(8, contentRadius * 0.62);
        var iconColor = empty ? p.Tertiary : new SolidColorBrush(stale ? p.StaleColor : p.ProviderColor(c.Provider));
        var top = center.Y - (icon + number * 1.05) / 2 - contentRadius * 0.04;
        DrawIcon(dc, c.Provider, new Rect(center.X - icon / 2, top, icon, icon), iconColor);
        var numberTop = top + icon + contentRadius * 0.04;
        if (stale)
        {
            Text(dc, empty ? "–" : "過期", number * 0.82, FontWeights.SemiBold, p.Secondary, new Point(center.X, numberTop + number * 0.05), o.PixelsPerDip);
        }
        else
        {
            Percent(dc, c.RemainingPct, number, c.State == RingState.Critical ? p.Critical : p.Primary, p.Secondary,
                    new Point(center.X, numberTop), o.PixelsPerDip);
        }

        if (c.State == RingState.TooFast)
        {
            // 右上角橘色徽章點（白邊）
            var dot = Math.Max(3, radius * 0.17);
            var at = new Point(center.X + radius * 0.72, center.Y - radius * 0.72);
            dc.DrawEllipse(Palette.Brush(Colors.Black, 0.16), null, new Point(at.X, at.Y + 0.6), dot + 1.6, dot + 1.6);
            dc.DrawEllipse(Brushes.White, null, at, dot + 1.4, dot + 1.4);
            dc.DrawEllipse(Palette.Brush(Palette.Rgb(0xFF9F0A), 1), null, at, dot, dot);
        }
    }

    public void DrawTab(DrawingContext dc, RingContent c, Point center, double radius, Rect visible, Palette p, RingFaceOptions o)
    {
        // 露出的半圓裡：圖示在上、% 在下，置中在看得見的那一半
        var x = visible.Left + visible.Width / 2 + (visible.Left < center.X ? -radius * 0.08 : radius * 0.08);
        var stale = c.State == RingState.Stale;
        var empty = c.Provider.Length == 0;
        var icon = radius * 0.42;
        var number = radius * 0.34;
        var top = center.Y - (icon + number) / 2 - 1;
        var iconColor = empty ? p.Tertiary : new SolidColorBrush(stale ? p.StaleColor : p.BarColor(c.Provider, c.State == RingState.Critical ? RingState.Critical : RingState.Normal));
        DrawIcon(dc, c.Provider, new Rect(x - icon / 2, top, icon, icon), iconColor);
        if (stale) Text(dc, empty ? "–" : "過期", number * 0.8, FontWeights.SemiBold, p.Secondary, new Point(x, top + icon + 1), o.PixelsPerDip);
        else Percent(dc, c.RemainingPct, number, c.State == RingState.Critical ? p.Critical : p.Primary, p.Secondary, new Point(x, top + icon + 0.5), o.PixelsPerDip);
        if (c.State == RingState.TooFast)
        {
            var dot = Math.Max(2.5, radius * 0.13);
            var at = new Point(x + radius * 0.3, center.Y - radius * 0.62);
            dc.DrawEllipse(Brushes.White, null, at, dot + 1.2, dot + 1.2);
            dc.DrawEllipse(Palette.Brush(Palette.Rgb(0xFF9F0A), 1), null, at, dot, dot);
        }
    }

    /// <summary>60 格刻度：每 5 格長一點；這個額度週期已經過去的格子較亮</summary>
    private static void DrawTicks(DrawingContext dc, RingContent c, Point center, double radius, double band, Palette p)
    {
        var elapsed = c.TimeRemaining is { } t ? (int)Math.Round((100 - t) * 0.6) : 0;
        var past = new Pen(p.Secondary, 0.9) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        var future = new Pen(Palette.Brush(p.Primary.Color, p.Dark ? 0.16 : 0.14), 0.9) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        past.Freeze();
        future.Freeze();
        for (var i = 0; i < 60; i++)
        {
            var angle = 2 * Math.PI * i / 60;
            var length = i % 5 == 0 ? band : band * 0.55;
            var (sin, cos) = (Math.Sin(angle), Math.Cos(angle));
            var a = new Point(center.X + radius * sin, center.Y - radius * cos);
            var b = new Point(center.X + (radius - length) * sin, center.Y - (radius - length) * cos);
            dc.DrawLine(i < elapsed ? past : future, a, b);
        }
    }

    /// <summary>外圈的淡漸層：上淺下深（WPF 沒有沿圓周的漸層）</summary>
    private static Brush Gradient(Color color, bool dark)
    {
        var light = Mix(color, Colors.White, dark ? 0.28 : 0.22);
        var brush = new LinearGradientBrush(light, color, new Point(0.2, 0), new Point(0.8, 1));
        brush.Freeze();
        return brush;
    }

    public static Color Mix(Color a, Color b, double t) => Color.FromArgb(
        (byte)Math.Round(a.A + (b.A - a.A) * t), (byte)Math.Round(a.R + (b.R - a.R) * t),
        (byte)Math.Round(a.G + (b.G - a.G) * t), (byte)Math.Round(a.B + (b.B - a.B) * t));

    public static void DrawIcon(DrawingContext dc, string provider, Rect rect, Brush fill)
    {
        dc.PushTransform(new TranslateTransform(rect.X, rect.Y));
        dc.PushTransform(new ScaleTransform(rect.Width / 24, rect.Height / 24));
        dc.DrawGeometry(fill, null, ProviderIcons.For(provider));
        dc.Pop();
        dc.Pop();
    }

    /// <summary>「63%」：% 縮小變淡；<paramref name="topCenter"/> 是文字上緣的中點</summary>
    public static void Percent(DrawingContext dc, int pct, double size, Brush number, Brush sign, Point topCenter, double pixelsPerDip)
    {
        var digits = Formatted(pct.ToString(CultureInfo.InvariantCulture), size, FontWeights.SemiBold, number, pixelsPerDip);
        var percent = Formatted("%", size * 0.62, FontWeights.SemiBold, sign, pixelsPerDip);
        var total = digits.WidthIncludingTrailingWhitespace + percent.WidthIncludingTrailingWhitespace + size * 0.04;
        var left = topCenter.X - total / 2;
        dc.DrawText(digits, new Point(left, topCenter.Y));
        dc.DrawText(percent, new Point(left + digits.WidthIncludingTrailingWhitespace + size * 0.04, topCenter.Y + digits.Baseline - percent.Baseline));
    }

    public static void Text(DrawingContext dc, string text, double size, FontWeight weight, Brush brush, Point topCenter, double pixelsPerDip)
    {
        var f = Formatted(text, size, weight, brush, pixelsPerDip);
        dc.DrawText(f, new Point(topCenter.X - f.WidthIncludingTrailingWhitespace / 2, topCenter.Y));
    }

    public static FormattedText Formatted(string text, double size, FontWeight weight, Brush brush, double pixelsPerDip) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(SystemLook.Font, FontStyles.Normal, weight, FontStretches.Normal), size, brush, pixelsPerDip);
}

/// <summary>
/// 懸浮圓環的玻璃質感（圓底與展開的膠囊共用）：上淺下深的半透明漸層、頂部淡淡的光澤、上亮下暗的 1px 漸層邊框、柔和陰影。
/// 不畫服務色的光暈。
/// </summary>
internal static class GlassDrawing
{
    /// <summary>四個角各自的圓角（展開到一半時從圓變成膠囊或外框）</summary>
    public static Geometry RoundedRect(Rect r, double topLeft, double topRight, double bottomRight, double bottomLeft)
    {
        double Fit(double v) => Math.Max(0, Math.Min(v, Math.Min(r.Width, r.Height) / 2));
        topLeft = Fit(topLeft);
        topRight = Fit(topRight);
        bottomRight = Fit(bottomRight);
        bottomLeft = Fit(bottomLeft);
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(new Point(r.Left + topLeft, r.Top), true, true);
            ctx.LineTo(new Point(r.Right - topRight, r.Top), true, false);
            if (topRight > 0) ctx.ArcTo(new Point(r.Right, r.Top + topRight), new Size(topRight, topRight), 0, false, SweepDirection.Clockwise, true, false);
            ctx.LineTo(new Point(r.Right, r.Bottom - bottomRight), true, false);
            if (bottomRight > 0) ctx.ArcTo(new Point(r.Right - bottomRight, r.Bottom), new Size(bottomRight, bottomRight), 0, false, SweepDirection.Clockwise, true, false);
            ctx.LineTo(new Point(r.Left + bottomLeft, r.Bottom), true, false);
            if (bottomLeft > 0) ctx.ArcTo(new Point(r.Left, r.Bottom - bottomLeft), new Size(bottomLeft, bottomLeft), 0, false, SweepDirection.Clockwise, true, false);
            ctx.LineTo(new Point(r.Left, r.Top + topLeft), true, false);
            if (topLeft > 0) ctx.ArcTo(new Point(r.Left + topLeft, r.Top), new Size(topLeft, topLeft), 0, false, SweepDirection.Clockwise, true, false);
        }
        g.Freeze();
        return g;
    }

    public static void Draw(DrawingContext dc, Geometry shape, Rect bounds, Palette p, bool critical = false)
    {
        // 柔和陰影：往下偏一點、由外往內加深的幾層描邊（沒有用 Effect，閒置時不需要重繪）
        dc.PushTransform(new TranslateTransform(0, 1.2));
        foreach (var (w, a) in new[] { (5.0, 0.035), (3.2, 0.05), (1.6, 0.08) })
        {
            dc.DrawGeometry(null, new Pen(Palette.Brush(Colors.Black, p.Dark ? a * 1.6 : a), w), shape);
        }
        dc.Pop();

        // 毛玻璃：上淺下深的半透明漸層
        var fill = p.Dark
            ? new LinearGradientBrush(Color.FromArgb(0xE6, 0x3A, 0x3A, 0x40), Color.FromArgb(0xEE, 0x1C, 0x1C, 0x21), 90)
            : new LinearGradientBrush(Color.FromArgb(0xEE, 0xFF, 0xFF, 0xFF), Color.FromArgb(0xE0, 0xEC, 0xEC, 0xF0), 90);
        fill.Freeze();
        dc.DrawGeometry(fill, null, shape);

        // 頂部淡淡的光澤（只在上面約 45%）
        var gloss = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0),
            EndPoint = new Point(0, 1),
            GradientStops =
            {
                new GradientStop(Color.FromArgb((byte)(p.Dark ? 0x22 : 0x70), 0xFF, 0xFF, 0xFF), 0),
                new GradientStop(Color.FromArgb(0, 0xFF, 0xFF, 0xFF), 0.45),
            },
        };
        gloss.Freeze();
        dc.DrawGeometry(gloss, null, shape);

        // 上亮下暗的漸層 1px 邊框
        var border = new LinearGradientBrush(
            p.Dark ? Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF),
            p.Dark ? Color.FromArgb(0x50, 0x00, 0x00, 0x00) : Color.FromArgb(0x26, 0x00, 0x00, 0x00), 90);
        border.Freeze();
        dc.DrawGeometry(null, new Pen(border, 1), shape);
        if (critical)
        {
            // 剩不到 20% 時玻璃內側一圈很淡的紅
            dc.DrawGeometry(null, new Pen(Palette.Brush(p.Critical.Color, 0.18), 2), shape);
        }
    }
}
