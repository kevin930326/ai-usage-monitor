using System;
using System.Windows;
using System.Windows.Media;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 懸浮圓環某一刻的畫面（視窗座標，DIP）。<see cref="Reveal"/>：0＝貼邊的半圓標籤、1＝圓環在原位；
/// <see cref="Expand"/>：0＝圓環、1＝完整展開的膠囊或外框。截圖與 <see cref="RingWindow"/> 共用。
/// </summary>
internal sealed record FloatingScene(
    RingContent Content,
    RingDetails Details,
    Palette Palette,
    IRingFace Face,
    bool Ticks,
    double RingDip,
    RingExpandDirection Direction,
    RingDock Dock,
    Point RingCenter,
    Point TabCenter,
    Rect? TabVisible,
    double Reveal,
    double Expand,
    double PixelsPerDip)
{
    /// <summary>展開後被推回工作區時，展開的內容（含圓環）跟著移動的距離；展開的過程中逐漸移過去</summary>
    public Vector Shift { get; init; }
}

internal static class FloatingRingRenderer
{
    public static void Draw(DrawingContext dc, FloatingScene s)
    {
        var p = s.Palette;
        var r = RingShape.DiscRadius(s.RingDip);
        var options = new RingFaceOptions(s.Ticks, s.PixelsPerDip);
        var critical = s.Content.State == RingState.Critical;

        if (s.Reveal <= 0 && s.TabVisible is { } visible)
        {
            // 貼邊收合：圓底的中心在工作區邊緣，視窗只涵蓋露出的那一半
            dc.PushClip(new RectangleGeometry(visible));
            var disc = new EllipseGeometry(s.TabCenter, r, r);
            GlassDrawing.Draw(dc, disc, disc.Bounds, p, critical);
            s.Face.DrawTab(dc, s.Content, s.TabCenter, r, visible, p, options);
            AgentOverlay.Draw(dc, s.Content.Agent?.State == AgentState.NeedsYou ? s.Content.Agent : null, Inset(disc, s.TabCenter, r), s.TabCenter, r, p);
            dc.Pop();
            return;
        }

        var reveal = Ease(s.Reveal);
        var center = new Point(s.TabCenter.X + (s.RingCenter.X - s.TabCenter.X) * reveal, s.TabCenter.Y + (s.RingCenter.Y - s.TabCenter.Y) * reveal);
        if (s.TabVisible is { } edge && s.Dock != RingDock.None)
        {
            // 從邊緣滑出後，邊緣到圓環之間留一條幾乎透明（但點得到）的區域：滑鼠停在最邊緣時不會一出一收地閃
            var x0 = s.Dock == RingDock.Left ? edge.Left : center.X;
            var x1 = s.Dock == RingDock.Left ? center.X : edge.Right;
            if (x1 > x0) dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)), null, new Rect(x0, center.Y - r, x1 - x0, 2 * r));
        }

        var e = Ease(Math.Clamp(s.Expand, 0, 1));
        if (e <= 0)
        {
            GlassDrawing.Draw(dc, new EllipseGeometry(center, r, r), new Rect(center.X - r, center.Y - r, 2 * r, 2 * r), p, critical);
            s.Face.Draw(dc, s.Content, center, r, p, options);
            AgentOverlay.Draw(dc, s.Content.Agent, Inset(new EllipseGeometry(center, r, r), center, r), center, r, p);
            return;
        }

        center += s.Shift * e;
        var full = RingShape.Shape(s.Direction, s.Dock, s.RingDip);
        var rect = new Rect(
            new Point(center.X + Lerp(-r, full.Left, e), center.Y + Lerp(-r, full.Top, e)),
            new Point(center.X + Lerp(r, full.Right, e), center.Y + Lerp(r, full.Bottom, e)));
        Geometry shape;
        if (s.Direction is RingExpandDirection.Left or RingExpandDirection.Right)
        {
            var radius = rect.Height / 2;
            shape = GlassDrawing.RoundedRect(rect, radius, radius, radius, radius);
        }
        else
        {
            // 外框：圓環那一角與圓底同心，其他三角較小
            var ringCorner = Lerp(r, r + RingShape.FramePad, e);
            var other = Lerp(r, RingShape.FrameCorner, e);
            var left = s.Dock != RingDock.Right;
            var down = s.Direction == RingExpandDirection.Down;
            shape = GlassDrawing.RoundedRect(rect,
                left && down ? ringCorner : other,
                !left && down ? ringCorner : other,
                !left && !down ? ringCorner : other,
                left && !down ? ringCorner : other);
        }
        GlassDrawing.Draw(dc, shape, rect, p, critical);
        s.Face.Draw(dc, s.Content, center, r, p, options);
        AgentOverlay.Draw(dc, s.Content.Agent, shape, center, r, p);

        var rowsOpacity = Math.Clamp((e - 0.35) / 0.65, 0, 1);
        if (rowsOpacity <= 0 || s.Details.Rows.Count == 0) return;
        var info = RingShape.Info(s.Direction, s.Dock, s.RingDip);
        var area = new Rect(center.X + info.Left, center.Y + info.Top, info.Width, info.Height);
        dc.PushClip(shape);
        dc.PushOpacity(rowsOpacity);
        var rowHeight = RingShape.RowsHeight / 2;
        for (var i = 0; i < s.Details.Rows.Count && i < 2; i++)
        {
            var row = new Rect(area.Left, area.Top + i * rowHeight, area.Width, rowHeight);
            // AI 要你注意時，第二行改成 AI 的狀態（第一行的額度保留）
            if (i == 1 && s.Content.Agent is { } agent) DrawAgentRow(dc, agent, row, p, s.PixelsPerDip);
            else DrawRow(dc, s.Details.Rows[i], row, p, s.PixelsPerDip);
        }
        if (s.Details.Rows.Count == 1 && s.Content.Agent is { } only)
        {
            DrawAgentRow(dc, only, new Rect(area.Left, area.Top + rowHeight, area.Width, rowHeight), p, s.PixelsPerDip);
        }
        dc.Pop();
        dc.Pop();
    }

    /// <summary>一行：圖示、名稱、（用得較快）、右邊 %；下面細進度條與重置倒數</summary>
    private static void DrawRow(DrawingContext dc, RingDetailRow row, Rect area, Palette p, double ppd)
    {
        var stale = row.State == RingState.Stale;
        var tint = p.BarColor(row.Provider, row.State);
        var iconBrush = new SolidColorBrush(stale ? p.StaleColor : p.ProviderColor(row.Provider));
        var top = area.Top + 3;
        GlassRingFace.DrawIcon(dc, row.Provider, new Rect(area.Left, top + 1, 12, 12), iconBrush);

        var pct = GlassRingFace.Formatted($"{row.RemainingPct}", 13, FontWeights.SemiBold, row.State == RingState.Critical ? p.Critical : p.Primary, ppd);
        var sign = GlassRingFace.Formatted("%", 9, FontWeights.SemiBold, p.Secondary, ppd);
        var pctLeft = area.Right - pct.WidthIncludingTrailingWhitespace - sign.WidthIncludingTrailingWhitespace - 0.5;
        dc.DrawText(pct, new Point(pctLeft, top - 1.5));
        dc.DrawText(sign, new Point(area.Right - sign.WidthIncludingTrailingWhitespace, top - 1.5 + pct.Baseline - sign.Baseline));

        var name = GlassRingFace.Formatted(row.Name, 11.5, FontWeights.SemiBold, p.Primary, ppd);
        name.MaxTextWidth = Math.Max(10, pctLeft - area.Left - 22);
        name.MaxLineCount = 1;
        name.Trimming = TextTrimming.CharacterEllipsis;
        dc.DrawText(name, new Point(area.Left + 17, top));
        if (row.TooFast)
        {
            var tag = GlassRingFace.Formatted("用得較快", 10, FontWeights.SemiBold, p.Notice, ppd);
            var x = area.Left + 17 + name.WidthIncludingTrailingWhitespace + 5;
            if (x + tag.WidthIncludingTrailingWhitespace < pctLeft - 4) dc.DrawText(tag, new Point(x, top + 1.5));
        }

        var countdown = GlassRingFace.Formatted(row.Countdown, 10, FontWeights.Normal, p.Secondary, ppd);
        var barTop = top + 19;
        var barRight = area.Right - (row.Countdown.Length > 0 ? countdown.WidthIncludingTrailingWhitespace + 8 : 0);
        var bar = new Rect(area.Left, barTop, Math.Max(10, barRight - area.Left), 3);
        dc.DrawRoundedRectangle(Palette.Brush(p.Primary.Color, p.Dark ? 0.14 : 0.1), null, bar, 1.5, 1.5);
        var filled = bar.Width * Math.Clamp(row.Fraction, 0, 1);
        if (filled > 0) dc.DrawRoundedRectangle(new SolidColorBrush(tint), null, new Rect(bar.Left, bar.Top, Math.Max(filled, 3), bar.Height), 1.5, 1.5);
        if (row.Countdown.Length > 0) dc.DrawText(countdown, new Point(area.Right - countdown.WidthIncludingTrailingWhitespace, barTop - 6));
    }

    /// <summary>AI 狀態的一行：圖示、「Claude Code 需要你」（狀態色）；下面一行說明</summary>
    private static void DrawAgentRow(DrawingContext dc, RingAgent agent, Rect area, Palette p, double ppd)
    {
        var top = area.Top + 3;
        var provider = AgentNames.Name(agent.Ai);
        GlassRingFace.DrawIcon(dc, provider, new Rect(area.Left, top + 1, 12, 12), new SolidColorBrush(p.ProviderColor(provider)));
        var title = GlassRingFace.Formatted(agent.Title, 11.5, FontWeights.SemiBold, AgentOverlay.Tint(agent, p), ppd);
        title.MaxTextWidth = Math.Max(10, area.Width - 17);
        title.MaxLineCount = 1;
        title.Trimming = TextTrimming.CharacterEllipsis;
        dc.DrawText(title, new Point(area.Left + 17, top));
        var detail = GlassRingFace.Formatted(agent.Detail, 10, FontWeights.Normal, p.Secondary, ppd);
        detail.MaxTextWidth = Math.Max(10, area.Width - 17);
        detail.MaxLineCount = 1;
        detail.Trimming = TextTrimming.CharacterEllipsis;
        dc.DrawText(detail, new Point(area.Left + 17, top + 15));
    }

    /// <summary>圓底內縮一點的外框（筆畫整個落在玻璃裡，不被視窗邊緣切掉）</summary>
    private static Geometry Inset(Geometry disc, Point center, double r) => disc is EllipseGeometry ? new EllipseGeometry(center, r - 1.2, r - 1.2) : disc;

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;

    /// <summary>動畫曲線（ease-out）：進度值本身是線性的，畫的時候套用</summary>
    private static double Ease(double t) => 1 - Math.Pow(1 - Math.Clamp(t, 0, 1), 3);
}
