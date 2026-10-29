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
        if (s.Face is MascotFace mascot)
        {
            DrawMascot(dc, s, mascot);
            return;
        }
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
        var (shape, rect) = Expanded(s, center, r, e);
        GlassDrawing.Draw(dc, shape, rect, p, critical);
        s.Face.Draw(dc, s.Content, center, r, p, options);
        AgentOverlay.Draw(dc, s.Content.Agent, shape, center, r, p);
        DrawRows(dc, s, shape, center, Math.Clamp((e - 0.35) / 0.65, 0, 1), p);
    }

    /// <summary>展開到 e 時的形狀：左右展開是膠囊，上下展開是外框</summary>
    private static (Geometry Shape, Rect Rect) Expanded(FloatingScene s, Point center, double r, double e)
    {
        var full = RingShape.Shape(s.Direction, s.Dock, s.RingDip);
        var rect = new Rect(
            new Point(center.X + Lerp(-r, full.Left, e), center.Y + Lerp(-r, full.Top, e)),
            new Point(center.X + Lerp(r, full.Right, e), center.Y + Lerp(r, full.Bottom, e)));
        if (s.Direction is RingExpandDirection.Left or RingExpandDirection.Right)
        {
            var radius = rect.Height / 2;
            return (GlassDrawing.RoundedRect(rect, radius, radius, radius, radius), rect);
        }
        // 外框：圓環那一角與圓底同心，其他三角較小
        var ringCorner = Lerp(r, r + RingShape.FramePad, e);
        var other = Lerp(r, RingShape.FrameCorner, e);
        var left = s.Dock != RingDock.Right;
        var down = s.Direction == RingExpandDirection.Down;
        return (GlassDrawing.RoundedRect(rect,
            left && down ? ringCorner : other,
            !left && down ? ringCorner : other,
            !left && !down ? ringCorner : other,
            left && !down ? ringCorner : other), rect);
    }

    /// <summary>展開後的兩行：額度（或 AI 的狀態）</summary>
    private static void DrawRows(DrawingContext dc, FloatingScene s, Geometry shape, Point center, double rowsOpacity, Palette p, DipRect? at = null)
    {
        // 沒有額度資料（還沒有 usage.json、服務都失敗）時仍寫出 AI 的狀態（Codex C-05）
        if (rowsOpacity <= 0 || (s.Details.Rows.Count == 0 && s.Content.Agent is null)) return;
        var info = at ?? RingShape.Info(s.Direction, s.Dock, s.RingDip);
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
        if (s.Details.Rows.Count < 2 && s.Content.Agent is { } only)
        {
            DrawAgentRow(dc, only, new Rect(area.Left, area.Top + s.Details.Rows.Count * rowHeight, area.Width, rowHeight), p, s.PixelsPerDip);
        }
        dc.Pop();
        dc.Pop();
    }

    private static readonly Brush MascotBody = Frozen(new SolidColorBrush(MascotFace.Body));
    private static readonly Pen MascotEdge = Frozen(new Pen(Frozen(new SolidColorBrush(Color.FromArgb(40, 255, 255, 255))), 1));
    private static readonly Pen AmberPen = Frozen(new Pen(Frozen(new SolidColorBrush(MascotFace.Amber)), 3));
    private static readonly Palette MascotPalette = new(true);
    private static readonly Brush TabShadow = Frozen(new RadialGradientBrush(new GradientStopCollection
    {
        new GradientStop(Color.FromArgb(90, 0, 0, 0), 0), new GradientStop(Color.FromArgb(40, 0, 0, 0), 0.55), new GradientStop(Color.FromArgb(0, 0, 0, 0), 1),
    }));

    /// <summary>收合時角色底下那一圈很淡的陰影：淺色、深色與花俏的桌布上都看得出輪廓（icons 第 6 部分）</summary>
    private static readonly Brush HeroShadow = Frozen(new RadialGradientBrush(new GradientStopCollection
    {
        new GradientStop(Color.FromArgb(70, 0, 0, 0), 0.55), new GradientStop(Color.FromArgb(28, 0, 0, 0), 0.78), new GradientStop(Color.FromArgb(0, 0, 0, 0), 1),
    }));
    /// <summary>展開的前 25%：膠囊從透明淡入（收合時沒有圓底）</summary>
    private const double BodyFadeIn = 0.25;

    private static T Frozen<T>(T freezable) where T : Freezable
    {
        freezable.Freeze();
        return freezable;
    }

    /// <summary>
    /// 角色（ADR-0015 第 6 節）：收合時沒有圓底，只有角色浮在桌面上、底下一圈很淡的陰影（透明處滑鼠穿透到後面的視窗：層疊視窗逐像素透明）；
    /// 展開時膠囊淡入，身體不透明（同 Mac 瀏海的卡片色，只有圓角外透明）、文字一律深色外觀；展開的大小跟著狀態機的面板進度
    /// （和 Mac 一樣的彈簧），額度兩行的透明度跟著 <see cref="MascotDirector.Content"/>。需要你時外框琥珀色、等你時外框白色脈動
    /// （收合時繞著頭）。
    /// </summary>
    private static void DrawMascot(DrawingContext dc, FloatingScene s, MascotFace face)
    {
        var r = RingShape.DiscRadius(s.RingDip);
        var controller = face.Controller;
        var t = controller.Rate == MascotRenderRate.Stopped ? controller.StoppedAt : controller.Time();
        var needsYou = s.Content.Agent?.State == AgentState.NeedsYou;
        if (s.Reveal <= 0 && s.TabVisible is { } visible)
        {
            // 從螢幕邊緣探出頭：沒有圓底，邊緣那側一團柔和的陰影；需要你時頭的外圈琥珀色
            dc.PushClip(new RectangleGeometry(visible));
            dc.DrawEllipse(TabShadow, null, s.TabCenter, r * 0.95, r * 0.95);
            face.DrawTab(dc, s.Content, s.TabCenter, r, visible, MascotPalette, new RingFaceOptions(false, s.PixelsPerDip));
            if (needsYou)
            {
                var inward = visible.Left + visible.Width / 2 > s.TabCenter.X ? 1 : -1;
                var head = MascotFace.HeroFill * r;
                var at = new Point(s.TabCenter.X + inward * head * (2 * MascotFace.TabShown - 1), s.TabCenter.Y);
                dc.DrawEllipse(null, AmberPen, at, head + 3, head + 3);
            }
            dc.Pop();
            return;
        }
        var reveal = Ease(s.Reveal);
        var center = new Point(s.TabCenter.X + (s.RingCenter.X - s.TabCenter.X) * reveal, s.TabCenter.Y + (s.RingCenter.Y - s.TabCenter.Y) * reveal);
        if (s.TabVisible is { } edge && s.Dock != RingDock.None)
        {
            var x0 = s.Dock == RingDock.Left ? edge.Left : center.X;
            var x1 = s.Dock == RingDock.Left ? center.X : edge.Right;
            if (x1 > x0) dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)), null, new Rect(x0, center.Y - r, x1 - x0, 2 * r));
        }
        // 視窗收著時沒有圓底；展開中照狀態機的進度（彈簧可能超過 1 一點，視窗只有完整展開那麼大）
        var progress = s.Expand > 0 && controller.Director is { } d ? Math.Clamp(d.PanelShape(t).Progress, 0, 1) : 0;
        center += s.Shift * progress;
        var (shape, rect) = progress > 0 ? Expanded(s, center, r, progress)
            : (new EllipseGeometry(center, r, r), new Rect(center.X - r, center.Y - r, 2 * r, 2 * r));
        var body = Math.Clamp(progress / BodyFadeIn, 0, 1);
        // 收合時的頭：陰影、琥珀色外圈與脈動繞著它
        var headRing = face.HeroPlacement(center, r, 0) is { } place ? new EllipseGeometry(place.Center, place.Radius + 3, place.Radius + 3) : shape;
        // 角色一律在膠囊左端（往左展開時從圓環移過去），兩行在角色右邊
        var slot = RingShape.MascotSlot(s.Direction, s.RingDip);
        // 陰影跟著角色移動（Codex C-01：往左展開時不傳 slot 會留在圓環的位置）
        if (body < 1 && face.HeroPlacement(center, r, progress, slot) is { } hero)
        {
            dc.PushOpacity(1 - body);
            dc.DrawEllipse(HeroShadow, null, hero.Center + new Vector(0, hero.Radius * 0.18), hero.Radius * 1.45, hero.Radius * 1.45);
            dc.Pop();
        }
        if (progress > 0)
        {
            dc.PushOpacity(body);
            dc.DrawGeometry(MascotBody, MascotEdge, shape);
            dc.Pop();
            dc.PushClip(shape);
            face.DrawRipple(dc, rect, s.PixelsPerDip);
            face.DrawHero(dc, center, r, progress, s.PixelsPerDip, bounds: rect, slot: slot);
            dc.Pop();
        }
        else
        {
            face.DrawHero(dc, center, r, 0, s.PixelsPerDip, bounds: rect, slot: slot);
        }
        if (progress > 0 && controller.Level is { } level) DrawLevel(dc, level, center + new Vector(slot * progress, 0), r, s.PixelsPerDip);
        if (progress <= 0 && face.ShowsPercent && s.Content.Provider.Length > 0) DrawPercent(dc, s.Content, center, r, s.PixelsPerDip);
        if (needsYou) dc.DrawGeometry(null, AmberPen, progress > 0 ? Inset(shape, center, r) : headRing);
        else if (controller.PulseAt is { } pulse && progress <= 0)
        {
            var opacity = MascotController.PulseOpacity((double)(controller.Time() - pulse) / MascotController.PulseMs);
            if (opacity > 0) dc.DrawGeometry(null, new Pen(new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), 255, 255, 255)), 3), headRing);
        }
        var rows = controller.Director?.Content(t).Opacity ?? 0;
        DrawRows(dc, s, shape, center, progress > 0 ? rows : 0, MascotPalette, RingShape.MascotInfo(s.Direction, s.RingDip));
    }

    /// <summary>「角色＋%」：圓底下緣的剩餘 %（剩不到 20% 紅色）</summary>
    private static void DrawPercent(DrawingContext dc, RingContent content, Point center, double r, double ppd)
    {
        var color = content.State == RingState.Critical ? MascotPalette.Critical : MascotPalette.Primary;
        var text = GlassRingFace.Formatted($"{content.RemainingPct}%", Math.Max(8, r * 0.36), FontWeights.SemiBold, color, ppd);
        var box = new Rect(center.X - text.WidthIncludingTrailingWhitespace / 2 - 3, center.Y + r * 0.92 - text.Height,
            text.WidthIncludingTrailingWhitespace + 6, text.Height);
        dc.DrawRoundedRectangle(MascotBody, null, box, box.Height / 2, box.Height / 2);
        dc.DrawText(text, new Point(box.Left + 3, box.Top));
    }

    /// <summary>等級（ADR-0020，只看這台電腦）：角色右下角的小標籤</summary>
    private static void DrawLevel(DrawingContext dc, int level, Point center, double r, double ppd)
    {
        var text = GlassRingFace.Formatted($"Lv {level}", 9, FontWeights.SemiBold, MascotPalette.Primary, ppd);
        var box = new Rect(center.X + r * 0.25, center.Y + r * 0.62, text.WidthIncludingTrailingWhitespace + 8, text.Height + 2);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(200, 0x2a, 0x2a, 0x30)), null, box, box.Height / 2, box.Height / 2);
        dc.DrawText(text, new Point(box.Left + 4, box.Top + 1));
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

        // 會在重置前用完時倒數換成預測（ADR-0018 第 3 節）：不到 60 分鐘紅色、其他提示色
        var bottomText = row.Forecast ?? row.Countdown;
        var countdown = row.Forecast is null
            ? GlassRingFace.Formatted(row.Countdown, 10, FontWeights.Normal, p.Secondary, ppd)
            : GlassRingFace.Formatted(row.Forecast, 10, FontWeights.SemiBold, row.Urgent ? p.Critical : p.Notice, ppd);
        var barTop = top + 19;
        var barRight = area.Right - (bottomText.Length > 0 ? countdown.WidthIncludingTrailingWhitespace + 8 : 0);
        var bar = new Rect(area.Left, barTop, Math.Max(10, barRight - area.Left), 3);
        dc.DrawRoundedRectangle(Palette.Brush(p.Primary.Color, p.Dark ? 0.14 : 0.1), null, bar, 1.5, 1.5);
        var filled = bar.Width * Math.Clamp(row.Fraction, 0, 1);
        if (filled > 0) dc.DrawRoundedRectangle(new SolidColorBrush(tint), null, new Rect(bar.Left, bar.Top, Math.Max(filled, 3), bar.Height), 1.5, 1.5);
        if (bottomText.Length > 0) dc.DrawText(countdown, new Point(area.Right - countdown.WidthIncludingTrailingWhitespace, barTop - 6));
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
