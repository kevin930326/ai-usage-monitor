using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using AIUsageMonitor.Core;
using AIUsageMonitor.Mascot;
using SkiaSharp;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 懸浮圖示的「角色」（ADR-0015 第 1 節「角色的繪製」、第 6 節）：<see cref="MascotPainter"/> 用 SkiaSharp 畫在記憶體裡的點陣圖，
/// 複製到 <see cref="WriteableBitmap"/> 交給 WPF（只在要重畫時）。
/// 狀態機的畫布座標（Mac 瀏海的 580×180）對到圖示：收合時迷你角色（mini）、展開時角色卡（card）的位置都對到圓底的中心，
/// 依面板展開的進度在兩者之間內插，所以過場、反應與 Mac 一樣，只是放在圓底上。漣漪對到展開的膠囊（粒子只畫一半）。
/// 收合時 AI 工作中或睡著的那一輪先畫好（<see cref="MascotCollapsedMotion"/>），之後只換圖。
/// </summary>
internal sealed class MascotFace(MascotController controller) : IRingFace
{
    /// <summary>角色的身體（球）半徑占圓底半徑的比例</summary>
    public const double HeroFill = 0.62;
    /// <summary>膠囊與圓底的顏色：不透明（同 Mac 瀏海的卡片色），只有圓角外透明</summary>
    public static readonly Color Body = Color.FromRgb(0x12, 0x12, 0x16);
    /// <summary>需要你的琥珀色（同 Mac 的 notchAmber）</summary>
    public static readonly Color Amber = Color.FromRgb(245, 190, 60);

    private readonly Slot hero = new();
    private readonly Slot ripple = new();
    private readonly Dictionary<object, List<BitmapSource>> loops = [];
    /// <summary>上一次畫角色時的對應（滑鼠的視窗座標換成畫布座標）</summary>
    private (Point Center, double K, double Ax, double Ay)? mapping;

    public MascotController Controller => controller;

    /// <summary>樣式「角色＋%」：收合時圓底下方另外寫剩餘 %</summary>
    public bool ShowsPercent { get; set; }

    public void Draw(DrawingContext dc, RingContent content, Point center, double radius, Palette palette, RingFaceOptions options) =>
        DrawHero(dc, center, radius, 0, options.PixelsPerDip);

    /// <summary>貼邊的標籤：露出半個頭加眼睛（靜態一格，不輪播、不看滑鼠）</summary>
    public void DrawTab(DrawingContext dc, RingContent content, Point center, double radius, Rect visible, Palette palette, RingFaceOptions options)
    {
        // 角色往畫面內側移一點，兩隻眼睛都露出來
        var inward = visible.Left + visible.Width / 2 > center.X ? 1 : -1;
        var heroCenter = new Point(center.X + inward * radius * HeroFill * 0.45, center.Y);
        DrawHero(dc, heroCenter, radius, 0, options.PixelsPerDip, still: true);
    }

    /// <summary>畫布座標的那一刻（停止時畫停住的那一刻）</summary>
    private long FrameTime() => controller.Rate == MascotRenderRate.Stopped ? controller.StoppedAt : controller.Time();

    /// <summary>角色畫在 center、圓底半徑 r；progress 是展開的進度（0 收合、1 展開）</summary>
    public void DrawHero(DrawingContext dc, Point center, double r, double progress, double ppd, bool still = false)
    {
        if (controller.Director is not { } director) return;
        var cfg = controller.Config.Hero;
        var p = Math.Clamp(progress, 0, 1);
        double ax = Lerp(cfg.Mini.X, cfg.Card.X, p), ay = Lerp(cfg.Mini.Y, cfg.Card.Y, p), ar = Lerp(cfg.Mini.Radius, cfg.Card.Radius, p);
        var k = HeroFill * r / ar;
        mapping = (center, k, ax, ay);
        // 跳一下、揮手時角色會超出圓底：畫的範圍是圓底的 2.3 倍
        var half = r * 1.15;
        var area = new Rect(center.X - half, center.Y - half, half * 2, half * 2);
        if (!still && controller.Loop is { } loop && controller.LoopKey is { } key && p <= 0)
        {
            var frames = LoopFrames(loop, key, area, ppd, k, ax, ay);
            var index = (int)(controller.Time() % (long)Math.Max(loop.Length, 1) * loop.Fps / 1000) % frames.Count;
            dc.DrawImage(frames[index], area);
            return;
        }
        var t = still ? controller.StoppedAt : FrameTime();
        var frame = MascotFrames.From(director, t, controller.Character, controller.Look, controller.EffectTime(t),
            still: still || !controller.Motion.MovesEyes(), gaze: still ? (0, 0) : null);
        dc.DrawImage(hero.Render(area, ppd, canvas => Paint(canvas, frame, area, ppd, k, ax, ay)), area);
    }

    private void Paint(SKCanvas canvas, MascotFrame frame, Rect area, double ppd, double k, double ax, double ay)
    {
        canvas.Scale((float)ppd);
        canvas.Translate((float)(area.Width / 2), (float)(area.Height / 2));
        canvas.Scale((float)k);
        canvas.Translate((float)-ax, (float)-ay);
        var placed = controller.Painter.DrawHero(frame, canvas);
        controller.Painter.DrawEffects(frame, placed, canvas);
    }

    private List<BitmapSource> LoopFrames(MascotCollapsedMotion loop, object key, Rect area, double ppd, double k, double ax, double ay)
    {
        var full = (key, Math.Round(area.Width, 2), ppd);
        if (loops.TryGetValue(full, out var cached)) return cached;
        // 換了狀態（工作↔睡覺、表情、外觀）：舊的一輪不會再用
        loops.Clear();
        var frames = Enumerable.Range(0, loop.Count)
            .Select(i => Slot.Snapshot(area, ppd, canvas => Paint(canvas, loop.Frame(loop.TimeOf(i)), area, ppd, k, ax, ay)))
            .ToList();
        loops[full] = frames;
        return frames;
    }

    /// <summary>展開的漣漪與碎片（畫布的 580×180 對到膠囊，粒子只畫一半）</summary>
    public void DrawRipple(DrawingContext dc, Rect capsule, double ppd)
    {
        if (controller.Director is not { Ripple: { } r } director || !controller.Motion.DrawsParticles()) return;
        var t = FrameTime();
        if (t >= r.EndTime) return;
        var frame = MascotFrames.From(director, t, controller.Character, controller.Look);
        var painter = controller.Painter;
        var s = capsule.Height / painter.PanelHeight;
        dc.DrawImage(ripple.Render(capsule, ppd, canvas =>
        {
            canvas.Scale((float)ppd);
            canvas.Translate((float)(capsule.Width / 2), (float)(capsule.Height / 2));
            canvas.Scale((float)s);
            canvas.Translate(-painter.Center.X, -painter.Center.Y);
            painter.DrawRipple(r, frame, canvas, every: 2);
        }), capsule);
    }

    /// <summary>視窗座標（DIP）換成畫布座標（手勢、點擊用）；還沒畫過時 null</summary>
    public Point? ToCanvas(Point local) =>
        mapping is { } m ? new Point(m.Ax + (local.X - m.Center.X) / m.K, m.Ay + (local.Y - m.Center.Y) / m.K) : null;

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;

    /// <summary>一塊重複使用的點陣圖：大小一樣時只覆寫像素</summary>
    private sealed class Slot
    {
        private SKBitmap? sk;
        private WriteableBitmap? wpf;

        public BitmapSource Render(Rect area, double ppd, Action<SKCanvas> paint)
        {
            var (w, h) = Size(area, ppd);
            if (sk is null || sk.Width != w || sk.Height != h)
            {
                sk?.Dispose();
                sk = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
                wpf = new WriteableBitmap(w, h, 96 * ppd, 96 * ppd, PixelFormats.Pbgra32, null);
            }
            using (var canvas = new SKCanvas(sk))
            {
                canvas.Clear(SKColors.Transparent);
                paint(canvas);
            }
            wpf!.WritePixels(new Int32Rect(0, 0, w, h), sk.GetPixels(), sk.ByteCount, sk.RowBytes);
            return wpf;
        }

        /// <summary>畫一次就固定的圖（收合時的一輪）</summary>
        public static BitmapSource Snapshot(Rect area, double ppd, Action<SKCanvas> paint)
        {
            var (w, h) = Size(area, ppd);
            using var bitmap = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
            using (var canvas = new SKCanvas(bitmap))
            {
                canvas.Clear(SKColors.Transparent);
                paint(canvas);
            }
            var image = BitmapSource.Create(w, h, 96 * ppd, 96 * ppd, PixelFormats.Pbgra32, null, bitmap.GetPixels(), bitmap.ByteCount, bitmap.RowBytes);
            image.Freeze();
            return image;
        }

        private static (int W, int H) Size(Rect area, double ppd) =>
            (Math.Max(1, (int)Math.Ceiling(area.Width * ppd)), Math.Max(1, (int)Math.Ceiling(area.Height * ppd)));
    }
}

/// <summary>角色右鍵選單的動作與表情（順序同 Mac 的 NotchMenu）</summary>
internal static class MascotMenu
{
    public static readonly (MascotRequest Request, string Title)[] Actions =
    [
        (MascotRequest.Hop, "跳一下"), (MascotRequest.Wave, "揮手"), (MascotRequest.Nod, "點頭"), (MascotRequest.Tilt, "歪頭"),
        (MascotRequest.Giggle, "偷笑"), (MascotRequest.Look, "東張西望"), (MascotRequest.Pinch, "捏一下"), (MascotRequest.Dizzy, "轉暈"),
        (MascotRequest.Shy, "害羞"), (MascotRequest.Scared, "嚇到"),
    ];

    public static readonly MascotMood[] Faces =
        [MascotMood.Happy, MascotMood.Worried, MascotMood.Sad, MascotMood.Sick, MascotMood.Surprised, MascotMood.Out, MascotMood.Stale];
}
