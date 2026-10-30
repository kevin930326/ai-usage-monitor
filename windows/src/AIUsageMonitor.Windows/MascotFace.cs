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
    /// <summary>收合時 AI 工作中、背景執行中或睡著：思考泡泡與 z 在角色右上方，角色縮小並往左下移，才放得進圓底</summary>
    private const double BusyFill = 0.44;
    private static readonly Vector BusyShift = new(-0.14, 0.10);
    /// <summary>膠囊與圓底的顏色：不透明（同 Mac 瀏海的卡片色），只有圓角外透明</summary>
    public static readonly Color Body = Color.FromRgb(0x12, 0x12, 0x16);
    /// <summary>需要你的琥珀色（同 Mac 的 notchAmber）</summary>
    public static readonly Color Amber = Color.FromRgb(245, 190, 60);

    private readonly Slot hero = new();
    /// <summary>展開時只有視線在轉：只畫角色周圍一塊（大小和整個膠囊不同，分開放才不會每次眨眼都重配點陣圖）</summary>
    private readonly Slot heroNear = new();
    private readonly Slot ripple = new();
    private readonly Dictionary<object, List<BitmapSource>> loops = [];
    /// <summary>上一次畫角色時的對應（滑鼠的視窗座標換成畫布座標）</summary>
    private (Point Center, double K, double Ax, double Ay)? mapping;
    /// <summary>上一次真的畫的角色（身體不會變時）：看滑鼠的一格和它看不出差別就不重畫（<see cref="ShowsSameFrame"/>）</summary>
    private (MascotFrame Frame, double Bob, double Scale, double Ppd)? drawn;
    /// <summary>視線、浮動差多少（裝置像素）以內算畫出來一樣（同 Mac MascotHeroLayerView.invisibleShift）</summary>
    private const double InvisibleShift = 0.25;

    public MascotController Controller => controller;

    /// <summary>
    /// 展開、只有視線在轉時（看滑鼠的高幀率）角色與 Lv 改畫在圓環視窗的另一層：每一格只重畫這一層，膠囊、額度兩行的文字不必重建
    /// （透明視窗每重繪一次整張都很貴）。展開時圓環畫一次就設好（<see cref="FloatingRingRenderer"/>，裡面再依 <see cref="DefersHero"/> 決定畫不畫），收合、貼邊時 null
    /// </summary>
    public Action<DrawingContext>? Overlay { get; set; }

    /// <summary>這一格的角色要不要改畫在 <see cref="Overlay"/></summary>
    public bool DefersHero(double progress) => progress >= 1 && controller.Rate == MascotRenderRate.GazeOpen;

    /// <summary>上一次畫角色時角色的中心（視窗座標，DIP；含展開的進度、往左展開的移動與推回工作區的距離）；還沒畫過時 null</summary>
    public Point? HeroCenter => mapping?.Center;

    /// <summary>
    /// 角色的中心與身體半徑（視窗座標，DIP）：收合時沒有圓底，陰影、需要你的琥珀色外圈與脈動都繞著它畫（icons 第 6 部分）。
    /// 和 <see cref="DrawHero"/> 同一套位置（工作中、睡著時縮小並往左下移）
    /// </summary>
    public (Point Center, double Radius)? HeroPlacement(Point center, double r, double progress, double slot = 0)
    {
        if (controller.Director is not { } director) return null;
        var p = Math.Clamp(progress, 0, 1);
        var busy = director.Mode is MascotMode.Work or MascotMode.Sleep or MascotMode.Think ? 1 - p : 0;
        // 身體在畫布上的半徑乘上縮放 k（DrawHero）剛好是 fill × r
        return (center + new Vector(slot * p, 0) + BusyShift * (r * busy), Lerp(HeroFill, BusyFill, busy) * r);
    }

    /// <summary>樣式「角色＋%」：收合時圓底下方另外寫剩餘 %</summary>
    public bool ShowsPercent { get; set; }

    public void Draw(DrawingContext dc, RingContent content, Point center, double radius, Palette palette, RingFaceOptions options) =>
        DrawHero(dc, center, radius, 0, options.PixelsPerDip);

    /// <summary>貼邊時露出頭的比例</summary>
    public const double TabShown = 0.6;
    /// <summary>貼邊時臉往螢幕內側轉（yaw）</summary>
    public const double TabYaw = 0.5;

    /// <summary>
    /// 貼邊的標籤（從螢幕邊緣探出頭）：center 是螢幕邊緣上的點。露出約 60% 的頭、臉朝螢幕內側；醒著時照常眨眼（不看滑鼠），
    /// 工作中、睡著照收合的一輪（貼右邊時左右翻過來，泡泡與 z 往螢幕內側）
    /// </summary>
    public void DrawTab(DrawingContext dc, RingContent content, Point center, double radius, Rect visible, Palette palette, RingFaceOptions options)
    {
        drawn = null;
        if (controller.Director is not { } director) return;
        var inward = visible.Left + visible.Width / 2 > center.X ? 1 : -1;
        var heroCenter = new Point(center.X + inward * radius * HeroFill * (2 * TabShown - 1), center.Y);
        if (controller.Loop is not null)
        {
            // 收合的一輪把角色往左下移、縮小（讓出泡泡與 z 的位置）：標籤上抵銷這個位移，頭照樣露出約 60%
            var busyCenter = new Point(center.X + inward * radius * BusyFill * (2 * TabShown - 1), center.Y);
            if (inward < 0) dc.PushTransform(new ScaleTransform(-1, 1, busyCenter.X, 0));
            DrawHero(dc, busyCenter - BusyShift * radius, radius, 0, options.PixelsPerDip);
            if (inward < 0) dc.Pop();
            return;
        }
        var cfg = controller.Config.Hero;
        var k = HeroFill * radius / cfg.Mini.Radius;
        var half = radius * 1.15;
        var area = new Rect(heroCenter.X - half, heroCenter.Y - half, half * 2, half * 2);
        var t = controller.Time();
        var frame = MascotFrames.From(director, t, controller.Character, controller.Look, controller.EffectTime(t),
            gaze: (inward * TabYaw, 0)) with { Blink = controller.Motion.MovesEyes() ? director.Blink(t, tab: true) : 0 };
        dc.DrawImage(hero.Render(area, options.PixelsPerDip, canvas => Paint(canvas, frame, options.PixelsPerDip, heroCenter - area.TopLeft, k, cfg.Mini.X, cfg.Mini.Y)), area);
    }

    /// <summary>畫布座標的那一刻（停止時畫停住的那一刻）</summary>
    private long FrameTime() => controller.Rate == MascotRenderRate.Stopped ? controller.StoppedAt : controller.Time();

    /// <summary>
    /// 角色畫在 center、圓底半徑 r；progress 是展開的進度（0 收合、1 展開）。展開時畫在整個膠囊 bounds 裡
    /// （過場中角色在膠囊中間，離圓底很遠）。slot：展開後角色卡的位置與 center 的距離（往左展開時角色移到膠囊左端，
    /// 過場與漣漪也以那裡為準，才在膠囊裡）
    /// </summary>
    public void DrawHero(DrawingContext dc, Point center, double r, double progress, double ppd, bool still = false, Rect? bounds = null,
                         double slot = 0)
    {
        if (controller.Director is not { } director) return;
        var cfg = controller.Config.Hero;
        var p = Math.Clamp(progress, 0, 1);
        var t = still ? controller.StoppedAt : FrameTime();
        // 錨點跟著角色自己的姿勢從迷你移到卡片（腳本 620 ms ExpoOut），不是面板的彈簧進度：兩者不同步時（展開剛開始，
        // 彈簧 0.12、姿勢已經 0.36）角色會偏到膠囊左下被裁掉。完整展開與收合時照舊
        var q = p is > 0 and < 1 && cfg.Card.Radius != cfg.Mini.Radius
            ? Math.Clamp((director.Pose(t)[MascotProp.R] - cfg.Mini.Radius) / (cfg.Card.Radius - cfg.Mini.Radius), 0, 1)
            : p;
        double ax = Lerp(cfg.Mini.X, cfg.Card.X, q), ay = Lerp(cfg.Mini.Y, cfg.Card.Y, q), ar = Lerp(cfg.Mini.Radius, cfg.Card.Radius, q);
        var busy = !still && director.Mode is MascotMode.Work or MascotMode.Sleep or MascotMode.Think ? 1 - p : 0;
        var heroCenter = center + new Vector(slot * p, 0) + BusyShift * (r * busy);
        var k = Lerp(HeroFill, BusyFill, busy) * r / ar;
        mapping = (heroCenter, k, ax, ay);
        // 收合時跳一下、揮手會超出圓底：畫的範圍是圓底的 2.3 倍
        var half = r * 1.15;
        var area = p > 0 && bounds is { } b ? b : new Rect(center.X - half, center.Y - half, half * 2, half * 2);
        // 完全展開、只有視線在轉（看滑鼠的高幀率）：只畫角色周圍一塊（同 Mac，提醒光環最大 3 倍身體半徑），
        // 不必每格把整個膠囊大小的點陣圖重畫、複製一次（ADR-0016 第 6 節「縮小重畫範圍」）
        var slotUsed = hero;
        if (p >= 1 && bounds is { } capsule && controller.Rate == MascotRenderRate.GazeOpen)
        {
            var reach = HeroFill * r * 3.1 + 6;
            var near = Rect.Intersect(capsule, new Rect(heroCenter.X - reach, heroCenter.Y - reach, reach * 2, reach * 2));
            if (!near.IsEmpty) (area, slotUsed) = (near, heroNear);
        }
        var origin = heroCenter - area.TopLeft;
        if (!still && controller.Loop is { } loop && controller.LoopKey is { } key && p <= 0)
        {
            drawn = null;
            var frames = LoopFrames(loop, key, area, ppd, origin, k, ax, ay);
            var index = (int)(controller.Time() % (long)Math.Max(loop.Length, 1) * loop.Fps / 1000) % frames.Count;
            dc.DrawImage(frames[index], area);
            return;
        }
        var frame = MascotFrames.From(director, t, controller.Character, controller.Look, controller.EffectTime(t),
            still: still || !controller.Motion.MovesEyes(), gaze: still ? (0, 0) : null, staticRemote: controller.StaticRemote);
        drawn = !still && controller.Loop is null && BodyIsRigid(frame) ? (frame, Bob(frame), k * ppd, ppd) : null;
        dc.DrawImage(slotUsed.Render(area, ppd, canvas => Paint(canvas, frame, ppd, origin, k, ax, ay)), area);
    }

    /// <summary>
    /// 看滑鼠的一格（<see cref="MascotController.FrameTick"/>）和上一次畫的看不出差別：視線差不到 1/4 個裝置像素（半徑 × 角度差）、
    /// 上下浮動也差不到 1/4 像素、其他都一樣（同 Mac，icons 第 4 部分第三版）。透明視窗每重畫一次整張都很貴，看不出差別的格就不畫
    /// </summary>
    /// <param name="ppd">視窗現在的每 DIP 像素數：換了 DPI 一定重畫（Fable F-06）</param>
    public bool ShowsSameFrame(double ppd)
    {
        if (drawn is not { } last || last.Ppd != ppd || controller.Director is not { } director || controller.Loop is not null) return false;
        var t = FrameTime();
        var frame = MascotFrames.From(director, t, controller.Character, controller.Look, controller.EffectTime(t),
            still: !controller.Motion.MovesEyes(), staticRemote: controller.StaticRemote);
        var a = last.Frame;
        if (!BodyIsRigid(frame) || !frame.Pose.Equals(a.Pose) || frame.Eyes != a.Eyes || frame.Mood != a.Mood || frame.Look?.Id != a.Look?.Id
            || frame.Character != a.Character || frame.ThinkingDots != a.ThinkingDots || frame.RemoteBadge != a.RemoteBadge
            || frame.RemoteBadgeAbove != a.RemoteBadgeAbove || frame.Sleeping != a.Sleeping || frame.Dozing != a.Dozing
            || frame.DozeRise != a.DozeRise || frame.StatusColor != a.StatusColor || frame.Blink != a.Blink)
            return false;
        var px = frame.Pose[MascotProp.R] * frame.Pose[MascotProp.Sc] * last.Scale;
        return Math.Abs(frame.GazeYaw - a.GazeYaw) * px < InvisibleShift && Math.Abs(frame.GazePitch - a.GazePitch) * px < InvisibleShift
               && Math.Abs(Bob(frame) - last.Bob) * last.Scale < InvisibleShift;
    }

    /// <summary>身體只會跟著視線轉（同 Mac MascotPainter.bodyIsRigid）：沒有晃動、發抖、敲鍵盤、揮手、呼吸、手、鍵盤、繞圈、冷汗，
    /// 外觀不是格子、線框或會動的特效，沒有在播的特效與轉暈的眼睛</summary>
    private static bool BodyIsRigid(MascotFrame frame)
    {
        var h = frame.Pose;
        MascotProp[] moving = [MascotProp.Sway, MascotProp.Shiver, MascotProp.Type, MascotProp.Wave, MascotProp.Breathe, MascotProp.Hands,
                               MascotProp.Kb, MascotProp.Orbit];
        if (moving.Any(p => Math.Abs(h[p]) >= 0.0001) || frame.Mood.Sweat() || frame.Ripple is not null) return false;
        if (frame.Look is { } look && (look.Style.IsGrid() || look.Style == MascotLookStyle.Wire || (frame.EffectTime is not null && look.Style.Animates())))
            return false;
        return frame.Eyes != MascotEyes.Spiral && !frame.Effects.Any(e => e.Progress(frame.Time) is not null);
    }

    /// <summary>上下浮動（畫布座標，同 <see cref="MascotPainter"/> 的位置）</summary>
    private static double Bob(MascotFrame frame) => Math.Sin(frame.Time / 480.0) * 1.4 * frame.Pose[MascotProp.R] / 40;

    /// <summary>origin：角色的錨點在畫的範圍裡的位置（DIP）</summary>
    private void Paint(SKCanvas canvas, MascotFrame frame, double ppd, Vector origin, double k, double ax, double ay)
    {
        canvas.Scale((float)ppd);
        canvas.Translate((float)origin.X, (float)origin.Y);
        canvas.Scale((float)k);
        canvas.Translate((float)-ax, (float)-ay);
        var placed = controller.Painter.DrawHero(frame, canvas);
        controller.Painter.DrawEffects(frame, placed, canvas);
    }

    private List<BitmapSource> LoopFrames(MascotCollapsedMotion loop, object key, Rect area, double ppd, Vector origin, double k, double ax, double ay)
    {
        var full = (key, Math.Round(area.Width, 2), ppd);
        if (loops.TryGetValue(full, out var cached)) return cached;
        // 換了狀態（工作↔睡覺、表情、外觀）：舊的一輪不會再用
        loops.Clear();
        var frames = Enumerable.Range(0, loop.Count)
            .Select(i => Slot.Snapshot(area, ppd, canvas => Paint(canvas, loop.Frame(loop.TimeOf(i)), ppd, origin, k, ax, ay)))
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
