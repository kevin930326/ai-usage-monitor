using AIUsageMonitor.Core;
using SkiaSharp;

namespace AIUsageMonitor.Mascot;

// 角色外觀的身體畫法（ADR-0021；數值同配色挑選頁的 body、fxGrid、fxWire、fxNeon）。和 Mac 的
// MascotLookRenderer.swift 是同一份畫法，逐段對照。座標：身體中心在原點、y 往下（呼叫端負責平移與縮放）。

public static class MascotLookPainter
{
    /// <summary>臉的位置（身體自己的座標，不含翻滾）：格子特效要知道眼睛落在哪些格子。
    /// PillOpen：膠囊眼睛張開的程度（0…1，已扣掉眨眼）；表情不是膠囊時 null（眼睛另外畫在上面）</summary>
    public readonly record struct Face(double Yaw, double Pitch, MascotHeroConfig.EyeConfig Eye, double? PillOpen);

    /// <summary>畫完身體後，呼叫端還要畫的眼睛（表情、眉毛也用這個顏色）；Glow：發光（ASCII、線框、霓虹）</summary>
    public sealed record EyeStyle(double[] Color, bool Glow);

    public static readonly double[] Ink = [0x12, 0x12, 0x12];

    /// <summary>迷你角色（收合時 R≈9）用格子少的畫法</summary>
    public static bool IsMini(double radius) => radius < 12;

    /// <summary>這個外觀要另外畫的眼睛；null 表示身體已經畫了（LED 的膠囊眼是不亮的燈、像素的膠囊眼對齊格子）</summary>
    public static EyeStyle? EyesFor(MascotLook? look, double radius, bool pill)
    {
        if (look is null) return new EyeStyle(Ink, false);
        return look.Style switch
        {
            MascotLookStyle.Solid or MascotLookStyle.Linear => new EyeStyle(look.Eye ?? Ink, false),
            MascotLookStyle.Ascii => new EyeStyle(MascotPainter.Mix(look.Color ?? Ink, [255, 255, 255], 0.55), true),
            MascotLookStyle.Wire => new EyeStyle([0xEA, 0xFD, 0xFF], true),
            MascotLookStyle.Neon => new EyeStyle(look.Color ?? Ink, true),
            // 大的 LED 眼睛是不亮的燈；迷你時格子太粗，另外畫暗色眼睛。表情落在格子之間的黑縫，用暗琥珀才看得到
            MascotLookStyle.Led => pill
                ? IsMini(radius) ? new EyeStyle([0x16, 0x0C, 0x02], false) : null
                : new EyeStyle(MascotPainter.Mix([20, 10, 0], look.Color ?? Ink, 0.35), false),
            MascotLookStyle.Pixel => pill ? null : new EyeStyle([0x11, 0x11, 0x14], false),
            _ => new EyeStyle(Ink, false),
        };
    }

    /// <summary>特效重複一輪的長度（毫秒）：取特效本身週期的整數倍、約 3 秒，接回開頭時看不出斷點。不會動的外觀是 null</summary>
    public static double? LoopDuration(MascotLook look, double R)
    {
        switch (look.Style)
        {
            case MascotLookStyle.Led:
                // 掃描光每 2.6R／(1/14) 毫秒掃過一次
                var scan = 2.6 * R * 14;
                return scan * Math.Max(1, Math.Round(3000 / scan, MidpointRounding.AwayFromZero));
            // 呼吸 sin(t/480)
            case MascotLookStyle.Neon: return 2 * Math.PI * 480;
            // 經線每轉 π／經線數就回到同樣的樣子
            case MascotLookStyle.Wire: return 2600 * Math.PI / (IsMini(R) ? 3 : 6);
            // 每 110 毫秒換一次跳字，取 27 次
            case MascotLookStyle.Ascii: return 110 * 27;
            default: return null;
        }
    }

    /// <summary>身體（不含光暈、手與另外畫的眼睛）。time 是特效的時間（毫秒）；null 時畫靜態的一格。
    /// Solid 由呼叫端用三階漸層畫（和服務色同一套，過場時從白色漸變）</summary>
    public static void DrawBody(MascotLook look, double R, Face face, long? time, SKCanvas canvas)
    {
        switch (look.Style)
        {
            case MascotLookStyle.Linear: DrawLinear(look, R, canvas); break;
            case MascotLookStyle.Led or MascotLookStyle.Pixel or MascotLookStyle.Ascii: DrawGrid(look, R, face, time, canvas); break;
            case MascotLookStyle.Wire: DrawWire(look, R, face, time, canvas); break;
            case MascotLookStyle.Neon: DrawNeon(look, R, time, canvas); break;
        }
    }

    /// <summary>手（半徑 r，中心 center）：線框、霓虹是發光的圓圈；直線漸層照身體；其他特效用主色的三階（回傳 false，由呼叫端畫）</summary>
    public static bool DrawHand(MascotLook look, SKPoint center, double r, SKCanvas canvas)
    {
        switch (look.Style)
        {
            case MascotLookStyle.Neon or MascotLookStyle.Wire:
            {
                var color = MascotPainter.Color(look.Color ?? Ink);
                using var glow = MascotPainter.Glow(color, r * 0.9);
                using var paint = MascotPainter.Stroke(color, Math.Max(1, r * 0.2));
                paint.ImageFilter = glow;
                canvas.DrawOval(MascotPainter.Oval(center.X, center.Y, r, r), paint);
                return true;
            }
            case MascotLookStyle.Linear:
                canvas.Save();
                canvas.Translate(center);
                DrawLinear(look, r, canvas);
                canvas.Restore();
                return true;
            default:
                return false;
        }
    }

    private static SKPath Circle(double r)
    {
        using var path = new SKPathBuilder();
        path.AddOval(MascotPainter.Oval(0, 0, r, r), SKPathDirection.Clockwise);
        return path.Detach();
    }

    // 直線漸層

    private static void DrawLinear(MascotLook look, double R, SKCanvas canvas)
    {
        if (look.Stops is not { Count: >= 2 } stops) return;
        canvas.Save();
        using var clip = Circle(R);
        canvas.ClipPath(clip, antialias: true);
        var a = (look.Angle ?? 135) * Math.PI / 180;
        double dx = Math.Cos(a) * R, dy = Math.Sin(a) * R;
        var locations = Enumerable.Range(0, stops.Count).Select(i => (float)i / (stops.Count - 1)).ToArray();
        using (var shader = SKShader.CreateLinearGradient(new SKPoint((float)-dx, (float)-dy), new SKPoint((float)dx, (float)dy),
                   stops.Select(s => MascotPainter.Color(s)).ToArray(), locations, SKShaderTileMode.Clamp))
        using (var paint = new SKPaint { Shader = shader, IsAntialias = true })
        {
            canvas.DrawRect(MascotPainter.Oval(0, 0, R, R), paint);
        }
        ShadeOver(R, 1, 0.55, canvas);
        canvas.Restore();
    }

    /// <summary>球面的高光與陰影（疊在平塗或漸層上）</summary>
    private static void ShadeOver(double R, double k, double highlight, SKCanvas canvas)
    {
        var rect = MascotPainter.Oval(0, 0, R, R);
        var hc = new SKPoint((float)(-0.38 * R), (float)(-0.46 * R));
        using (var shader = SKShader.CreateTwoPointConicalGradient(hc, (float)(R * 0.04), hc, (float)(R * 0.95),
                   [MascotPainter.Rgba(1, 1, 1, highlight * k), MascotPainter.Rgba(1, 1, 1, 0)], [0, 1], SKShaderTileMode.Clamp))
        using (var paint = new SKPaint { Shader = shader, IsAntialias = true })
        {
            canvas.DrawRect(rect, paint);
        }
        var sc = new SKPoint((float)(-0.08 * R), (float)(-0.08 * R));
        using (var shader = SKShader.CreateTwoPointConicalGradient(sc, (float)(R * 0.5), sc, (float)(R * 1.22),
                   [MascotPainter.Rgba(0, 0, 0, 0), MascotPainter.Rgba(0, 0, 0, 0.4 * k)], [0, 1], SKShaderTileMode.Clamp))
        using (var paint = new SKPaint { Shader = shader, IsAntialias = true })
        {
            canvas.DrawRect(rect, paint);
        }
    }

    // 格子特效（LED、像素、ASCII）

    private const string Glyphs = ".:-=+*#%@";
    private const string MiniGlyphs = ".:+*";

    private static void DrawGrid(MascotLook look, double R, Face face, long? time, SKCanvas canvas)
    {
        if (look.Color is null) return;
        var mini = IsMini(R);
        var cell = (look.Style, mini) switch
        {
            (MascotLookStyle.Ascii, true) => 2 * R / 5.6,
            (MascotLookStyle.Led, true) => 2 * R / 7,
            (_, true) => 2 * R / 9,
            (MascotLookStyle.Ascii, false) => Math.Max(4, R / 6.5),
            _ => Math.Max(3, R / 8.5),
        };
        var n = (int)Math.Ceiling(2.1 * R / cell) | 1;
        var cx = n / 2.0;
        long? frame = time is { } t ? t / 110 : null;
        var font = look.Style == MascotLookStyle.Ascii ? GlyphFont.Shared(mini ? cell * 1.35 : cell * 1.3) : null;
        var set = mini ? MiniGlyphs : Glyphs;

        using var paint = new SKPaint { IsAntialias = true };
        // 每格的亮度與顏色只和外觀、大小、視線、眼睛有關：快取起來，每一格特效只重畫
        foreach (var c in GridCells.Cells(look, R, cell, n, face, set.Length))
        {
            paint.Color = c.Color;
            switch (look.Style)
            {
                case MascotLookStyle.Ascii:
                {
                    if (font is null) continue;
                    var index = c.Index;
                    if (frame is { } f)
                    {
                        var h = Hash(c.I, c.J, f);
                        if (h < 0.07) index += h < 0.035 ? 1 : -1;
                    }
                    index = Math.Clamp(index, 0, set.Length - 1);
                    font.Fill(set[index], c.X, c.Y, paint, canvas);
                    break;
                }
                case MascotLookStyle.Led:
                {
                    var d = cell * (mini ? 0.4 : 0.38);
                    canvas.DrawOval(MascotPainter.Oval(c.X, c.Y, d, d), paint);
                    break;
                }
                default:
                    canvas.DrawRect((float)(c.X - cell / 2), (float)(c.Y - cell / 2), (float)(cell + 0.6), (float)(cell + 0.6), paint);
                    break;
            }
        }

        if (look.Style == MascotLookStyle.Pixel && face.PillOpen is { } open)
        {
            // 像素的眼睛對齊格子、實心
            paint.Color = MascotPainter.Color([0x11, 0x11, 0x14]);
            foreach (var s in new[] { -1.0, 1.0 })
            {
                if (Project(face.Yaw + s * face.Eye.Yaw, face.Pitch + face.Eye.Pitch, R) is not { } q) continue;
                var gi = Math.Round(q.X / cell + cx - 0.5, MidpointRounding.AwayFromZero);
                var gj = Math.Round(q.Y / cell + cx - 0.5, MidpointRounding.AwayFromZero);
                var eh = open > 0.5 ? (mini ? 2 : Math.Max(2, Math.Round(R * face.Eye.Height / cell, MidpointRounding.AwayFromZero))) : 1;
                var ew = mini ? 1 : Math.Max(1, Math.Round(R * face.Eye.Width / cell, MidpointRounding.AwayFromZero));
                canvas.DrawRect((float)((gi - cx) * cell - (ew - 1) * cell / 2), (float)((gj - cx - (eh - 1) / 2) * cell),
                    (float)(ew * cell + 0.6), (float)(eh * cell + 0.6), paint);
            }
        }

        if (look.Style == MascotLookStyle.Led && time is { } now)
        {
            // 一道往下掃的光
            var by = -R + now / 14.0 % (2.6 * R);
            canvas.Save();
            using var clip = Circle(R);
            canvas.ClipPath(clip, antialias: true);
            var band = new SKRect((float)-R, (float)(by - R * 0.2), (float)R, (float)by);
            using var shader = SKShader.CreateLinearGradient(new SKPoint(0, band.Top), new SKPoint(0, band.Bottom),
                [MascotPainter.Rgba(1, 1, 1, 0), MascotPainter.Rgba(1, 1, 1, 0.12)], [0, 1], SKShaderTileMode.Clamp);
            using var light = new SKPaint { Shader = shader };
            canvas.DrawRect(band, light);
            canvas.Restore();
        }
    }

    /// <summary>膠囊眼睛在身體座標中的範圍（寬 0.27R、高 0.52R × 張開，至少 0.08R）</summary>
    private readonly record struct Pill(double X, double Y, double W, double H)
    {
        public bool Contains(double px, double py)
        {
            var r = Math.Min(W, H) / 2;
            double dx = Math.Max(Math.Abs(px - X) - (W / 2 - r), 0), dy = Math.Max(Math.Abs(py - Y) - (H / 2 - r), 0);
            return dx * dx + dy * dy <= r * r;
        }
    }

    private static List<Pill> PillRects(Face face, double R, double open) =>
        new[] { -1.0, 1.0 }
            .Select(s => Project(face.Yaw + s * face.Eye.Yaw, face.Pitch + face.Eye.Pitch, R))
            .OfType<(double X, double Y, double Fx, double Fy)>()
            .Select(q => new Pill(q.X, q.Y, R * face.Eye.Width * q.Fx, Math.Max(R * face.Eye.Height * q.Fy * open, R * 0.08)))
            .ToList();

    private static (double X, double Y, double Fx, double Fy)? Project(double yaw, double pitch, double R)
    {
        var cz = Math.Cos(yaw) * Math.Cos(pitch);
        if (cz <= 0.05) return null;
        return (Math.Sin(yaw) * Math.Cos(pitch) * R, -Math.Sin(pitch) * R, Math.Max(0.2, Math.Abs(Math.Cos(yaw))), Math.Max(0.2, Math.Cos(pitch)));
    }

    /// <summary>白→#C4C4C4→#505050 球面漸層在 (x, y) 的亮度（直接解兩圓的錐形漸層，同 Swift sphereLuminance）</summary>
    public static double SphereLuminance(double x, double y, double r)
    {
        double c0x = -0.38 * r, c0y = -0.46 * r, r0 = 0.04 * r;
        double dcx = 0.30 * r, dcy = 0.38 * r, dr = 1.18 * r;
        double qx = x - c0x, qy = y - c0y;
        // |q − t·dc|² = (r0 + t·dr)²
        var a = dcx * dcx + dcy * dcy - dr * dr;
        var b = qx * dcx + qy * dcy + r0 * dr;
        var c = qx * qx + qy * qy - r0 * r0;
        var disc = b * b - a * c;
        if (disc < 0 || a == 0) return 1;
        var s = Math.Sqrt(disc);
        var roots = new[] { (b + s) / a, (b - s) / a }.Where(t => r0 + t * dr >= 0).ToList();
        var u = Math.Clamp(roots.Count == 0 ? 0 : roots.Max(), 0, 1);
        double l0 = 1.0, l1 = 196.0 / 255, l2 = 80.0 / 255;
        return u < 0.52 ? l0 + (l1 - l0) * u / 0.52 : l1 + (l2 - l1) * (u - 0.52) / 0.48;
    }

    /// <summary>規格頁的 hash（字元跳動用）</summary>
    public static double Hash(double i, double j, double k)
    {
        var s = Math.Sin(i * 12.9898 + j * 78.233 + k * 37.719) * 43758.5453;
        return s - Math.Floor(s);
    }

    /// <summary>格子特效每格算好的位置、亮度、顏色與字元（ASCII 跳字前）</summary>
    internal readonly record struct GridCell(int I, int J, double X, double Y, SKColor Color, int Index);

    internal static GridCell? MakeCell(MascotLook look, int i, int j, double x, double y, double lum, int glyphCount)
    {
        if (look.Color is not { } color) return null;
        switch (look.Style)
        {
            case MascotLookStyle.Ascii:
                if (lum < 0.18) return null;
                var index = (int)Math.Round((lum - 0.3) / 0.7 * (glyphCount - 1), MidpointRounding.AwayFromZero);
                return new GridCell(i, j, x, y, MascotPainter.Color(color, 0.3 + 0.7 * lum), index);
            case MascotLookStyle.Led:
                var c = lum < 0.18 ? MascotPainter.Rgba(1, 1, 1, 0.07) : MascotPainter.Color(MascotPainter.Mix([20, 10, 0], color, Math.Min(1, lum * 1.1)));
                return new GridCell(i, j, x, y, c, 0);
            default:
                if (look.EffectTint is not { } tint) return null;
                var shade = lum < 0.18 ? tint.Mid : lum > 0.82 ? tint.Light : lum > 0.58 ? tint.Mid : tint.Shade;
                return new GridCell(i, j, x, y, MascotPainter.Color(shade), 0);
        }
    }

    // 線框球、霓虹

    private static void DrawWire(MascotLook look, double R, Face face, long? time, SKCanvas canvas)
    {
        if (look.Color is not { } color) return;
        var mini = IsMini(R);
        var full = MascotPainter.Oval(0, 0, R, R);
        using (var fill = MascotPainter.Fill(MascotPainter.Rgba(4 / 255.0, 14 / 255.0, 30 / 255.0, 0.88)))
        {
            canvas.DrawOval(full, fill);
        }
        // 所有線條畫在同一層，發光只算一次（每條線各算一次陰影很花 CPU）
        using var glow = MascotPainter.Glow(MascotPainter.Color(color), mini ? R * 0.5 : R * 0.12);
        using var layer = new SKPaint { ImageFilter = glow };
        canvas.SaveLayer(layer);
        using var stroke = MascotPainter.Stroke(MascotPainter.Color(color), Math.Max(1, R * 0.022), round: false);
        // 經線：慢慢轉，看滑鼠時跟著轉向
        var rot = (time ?? 0) / 2600.0 + face.Yaw * 1.4;
        var meridians = mini ? 3 : 6;
        for (var k = 0; k < meridians; k++)
        {
            var ph = rot + k * Math.PI / meridians;
            var rx = Math.Max(0.5, Math.Abs(Math.Cos(ph)) * R);
            stroke.Color = MascotPainter.Color(color, 0.25 + 0.45 * Math.Abs(Math.Sin(ph + Math.PI / 2)));
            canvas.DrawOval(MascotPainter.Oval(0, 0, rx, R), stroke);
        }
        foreach (var l in mini ? [0.0] : new[] { -60.0, -30, 0, 30, 60 })
        {
            var la = l * Math.PI / 180 + face.Pitch * 0.5;
            double yy = R * Math.Sin(la), rx = R * Math.Cos(la);
            if (rx <= 0) continue;
            stroke.Color = MascotPainter.Color(color, 0.5);
            canvas.DrawOval(MascotPainter.Oval(0, yy, rx, rx * 0.2), stroke);
        }
        stroke.Color = MascotPainter.Color(color);
        stroke.StrokeWidth = (float)Math.Max(1, R * 0.035);
        canvas.DrawOval(full, stroke);
        canvas.Restore();
    }

    private static void DrawNeon(MascotLook look, double R, long? time, SKCanvas canvas)
    {
        if (look.Color is not { } color) return;
        // 呼吸：靜態時是最亮的一格
        var pulse = time is { } t ? 0.75 + 0.25 * Math.Sin(t / 480.0) : 1;
        var ring = MascotPainter.Oval(0, 0, R * 0.96, R * 0.96);
        using (var fill = MascotPainter.Fill(new SKColor(0x0B, 0x07, 0x10)))
        {
            canvas.DrawOval(MascotPainter.Oval(0, 0, R, R), fill);
        }
        using (var glow = MascotPainter.Glow(MascotPainter.Color(color), R * 0.45 * pulse))
        using (var stroke = MascotPainter.Stroke(MascotPainter.Color(color), Math.Max(1.3, R * 0.07), round: false))
        {
            stroke.ImageFilter = glow;
            canvas.DrawOval(ring, stroke);
        }
        using (var stroke = MascotPainter.Stroke(MascotPainter.Rgba(1, 1, 1, 0.6 * pulse), Math.Max(1, R * 0.018), round: false))
        {
            canvas.DrawOval(ring, stroke);
        }
    }

    /// <summary>格子特效的快取：同一個外觀、大小、視線與眼睛只算一次（收合時姿勢停住，特效每秒十幾格都是同一份）</summary>
    private static class GridCells
    {
        private readonly record struct Key(string Look, double Radius, double Cell, double Yaw, double Pitch, double? Open);

        private static readonly Dictionary<Key, List<GridCell>> Cache = [];
        private static readonly Lock CacheLock = new();

        public static List<GridCell> Cells(MascotLook look, double R, double cell, int n, Face face, int glyphCount)
        {
            var key = new Key(look.Id, R, cell, face.Yaw, face.Pitch, face.PillOpen);
            lock (CacheLock)
            {
                if (Cache.TryGetValue(key, out var hit)) return hit;
                double r = R / cell, cx = n / 2.0;
                var inside = r * r * (IsMini(R) ? 0.9 : 0.97);
                var pills = face.PillOpen is { } open ? PillRects(face, R, open) : [];
                var cells = new List<GridCell>();
                for (var j = 0; j < n; j++)
                {
                    for (var i = 0; i < n; i++)
                    {
                        double ddx = i + 0.5 - cx, ddy = j + 0.5 - cx;
                        if (ddx * ddx + ddy * ddy > inside) continue;
                        double ox = ddx * cell, oy = ddy * cell;
                        var lum = pills.Any(p => p.Contains(ox, oy)) ? 0 : SphereLuminance(ox, oy, R);
                        if (MakeCell(look, i, j, ox, oy, lum, glyphCount) is { } c) cells.Add(c);
                    }
                }
                // 看滑鼠、眨眼時每格的鍵都不同：只留最近的一些
                if (Cache.Count > 48) Cache.Clear();
                Cache[key] = cells;
                return cells;
            }
        }
    }

    /// <summary>ASCII 用的等寬粗體字（Windows 是 Consolas，Mac 測試時是 Menlo）；每個大小只建一次</summary>
    private sealed class GlyphFont
    {
        private static SKTypeface? typeface;
        private static readonly Dictionary<int, GlyphFont> Cache = [];
        private static readonly Lock CacheLock = new();

        private readonly SKFont font;
        private readonly float middle;

        private GlyphFont(float size)
        {
            typeface ??= new[] { "Consolas", "Menlo", "Cascadia Mono" }
                .Select(name => SKTypeface.FromFamilyName(name, SKFontStyle.Bold))
                .FirstOrDefault(t => t is not null && t.FamilyName != SKTypeface.Default.FamilyName)
                ?? SKTypeface.FromFamilyName(null, SKFontStyle.Bold);
            font = new SKFont(typeface, size);
            // textBaseline middle：基線放在中心往下約 x 高度的一半
            middle = font.Metrics.XHeight / 2 + 0.5f;
        }

        /// <summary>大小取到 0.1 pt</summary>
        public static GlyphFont Shared(double size)
        {
            var key = (int)Math.Round(size * 10, MidpointRounding.AwayFromZero);
            lock (CacheLock)
            {
                if (Cache.TryGetValue(key, out var hit)) return hit;
                var made = new GlyphFont(key / 10f);
                if (Cache.Count > 32) Cache.Clear();
                Cache[key] = made;
                return made;
            }
        }

        public void Fill(char ch, double x, double y, SKPaint paint, SKCanvas canvas)
        {
            var text = ch.ToString();
            var advance = font.MeasureText(text);
            canvas.DrawText(text, (float)(x - advance / 2), (float)(y + middle), SKTextAlign.Left, font, paint);
        }
    }
}
