using AIUsageMonitor.Core;
using SkiaSharp;

namespace AIUsageMonitor.Mascot;

// 角色的繪製（數值同 notch-demo.html 的 drawHero、drawWave、drawFX）。和 Mac 的 MascotDrawing.swift MascotPainter
// 是同一份畫法，逐段對照；只依 MascotFrame 畫，不保存狀態。數字從 shared/mascot-anim.json 讀，
// 表情內部的形狀（眼睛、眉毛、冷汗、z、愛心）和 Mac 一樣寫在這裡（ADR-0016 第 3 節）。

public sealed class MascotPainter(MascotConfig config)
{
    public MascotConfig Config { get; } = config;
    /// <summary>畫布寬（漣漪碰到邊緣的位置、粒子的淡出依它計算）</summary>
    public double CanvasWidth { get; init; } = 580;
    public double PanelHeight { get; init; } = 180;
    public SKPoint Center { get; init; } = new(290, 95);

    private MascotHeroConfig Hero => Config.Hero;

    public void Draw(MascotFrame frame, SKCanvas canvas, bool particles)
    {
        if (particles && frame.Ripple is { } ripple) DrawRipple(ripple, frame, canvas);
        var placed = DrawHero(frame, canvas);
        DrawEffects(frame, placed, canvas);
    }

    // 顏色

    internal static double[] Mix(double[] a, double[] b, double t) => a.Zip(b, (x, y) => x + (y - x) * t).ToArray();

    internal static SKColor Color(double[] c, double alpha = 1) =>
        new(Byte(c[0]), Byte(c[1]), Byte(c[2]), Byte(Math.Clamp(alpha, 0, 1) * 255));

    internal static SKColor Rgba(double r, double g, double b, double alpha = 1) =>
        new(Byte(r * 255), Byte(g * 255), Byte(b * 255), Byte(Math.Clamp(alpha, 0, 1) * 255));

    private static byte Byte(double v) => (byte)Math.Clamp(Math.Round(v, MidpointRounding.AwayFromZero), 0, 255);

    internal static SKColor WithAlpha(SKColor color, double alpha) =>
        color.WithAlpha(Byte(color.Alpha * Math.Clamp(alpha, 0, 1)));

    private double[] GlowColor(MascotFrame frame) =>
        Mix(Config.Palette.White.Glow, frame.Look?.Glow ?? frame.Character.Tint(Config.Palette).Glow, frame.Pose[MascotProp.Tint]);

    /// <summary>身體三階漸層的目標色：服務色、外觀的三階或特效主色的三階；直線漸層、線框、霓虹沒有（過場時先畫白色）</summary>
    private (double[] Light, double[] Mid, double[] Shade)? BodyTint(MascotFrame frame)
    {
        if (frame.Look is not { } look)
        {
            var tint = frame.Character.Tint(Config.Palette);
            return (tint.Light, tint.Mid, tint.Shade);
        }
        if (look.Style.IsGrid()) return look.EffectTint;
        return look.Style == MascotLookStyle.Solid ? (look.Light ?? [], look.Mid ?? [], look.Shade ?? []) : null;
    }

    /// <summary>思考泡泡亮起的顏色：服務色與單色外觀用淺色、直線漸層用最亮的一段、特效外觀用主色</summary>
    private double[] ThinkingColor(MascotFrame frame)
    {
        if (frame.Look is not { } look) return frame.Character.Tint(Config.Palette).Light;
        return look.Style switch
        {
            MascotLookStyle.Solid => look.Light ?? Config.Palette.White.Light,
            MascotLookStyle.Linear => look.Stops?.MaxBy(s => s.Sum()) ?? Config.Palette.White.Light,
            _ => look.Color ?? Config.Palette.White.Light,
        };
    }

    private double[] StatusColor(double level)
    {
        var s = Config.Palette.Status;
        return level < 1 ? Mix(s.Normal, s.High, Math.Max(level, 0)) : Mix(s.High, s.Out, Math.Min(level - 1, 1));
    }

    internal static SKPaint Fill(SKColor color) => new() { Color = color, IsAntialias = true, Style = SKPaintStyle.Fill };

    internal static SKPaint Stroke(SKColor color, double width, bool round = true) => new()
    {
        Color = color, IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = (float)width,
        StrokeCap = round ? SKStrokeCap.Round : SKStrokeCap.Butt, StrokeJoin = round ? SKStrokeJoin.Round : SKStrokeJoin.Miter,
    };

    /// <summary>SwiftUI／CoreGraphics 的陰影半徑換成高斯模糊的 sigma</summary>
    internal static SKImageFilter Glow(SKColor color, double radius) =>
        SKImageFilter.CreateDropShadow(0, 0, (float)(radius / 2), (float)(radius / 2), color);

    internal static SKRect Oval(double cx, double cy, double rx, double ry) =>
        new((float)(cx - rx), (float)(cy - ry), (float)(cx + rx), (float)(cy + ry));

    // 漣漪

    private static readonly double[][] ConfettiColors = [[255, 120, 150], [255, 170, 80], [90, 210, 190], [150, 120, 255], [255, 220, 120]];

    /// <summary>漣漪、碎片與邊緣弧光（畫布座標）。every：每幾顆粒子畫一顆（Windows 的膠囊比瀏海小，畫一半）</summary>
    public void DrawRipple(MascotRipple ripple, MascotFrame frame, SKCanvas canvas, int every = 1)
    {
        var now = frame.Time;
        double cx = Center.X, cy = Center.Y;
        var cfg = ripple.Config;
        canvas.SaveLayer();
        var tinted = Color(GlowColor(frame));
        using var particle = new SKPaint { IsAntialias = true, BlendMode = SKBlendMode.Plus };
        foreach (var ring in ripple.Rings)
        {
            if (ripple.RingState(ring, now) is not { } state) continue;
            for (var i = 0; i < ring.Particles.Count; i += Math.Max(every, 1))
            {
                var p = ring.Particles[i];
                var rr = state.Radius + p.Jitter + Math.Sin(p.Angle * cfg.EdgeWobbleLobes + ring.Seed) * cfg.EdgeWobblePx;
                double px = cx + rr * Math.Cos(p.Angle), py = cy + rr * Math.Sin(p.Angle) * cfg.VerticalSquash;
                if (py < 4 || py > PanelHeight - 4) continue;
                var edge = Math.Clamp((cx - cfg.EdgeInsetPx - Math.Abs(px - cx)) / cfg.EdgeFadePx, 0, 1);
                if (edge <= 0) continue;
                var twinkle = 0.35 + 0.65 * Math.Abs(Math.Sin(p.Phase + now / cfg.TwinkleMs));
                particle.Color = WithAlpha(p.Tinted ? tinted : SKColors.White, state.Fade * edge * twinkle);
                canvas.DrawRect((float)px, (float)py, (float)p.Size, (float)p.Size, particle);
            }
        }
        // 碎片
        var c = cfg.Confetti;
        if (now >= ripple.ConfettiStart && now < ripple.ConfettiStart + c.Ms)
        {
            var u = (double)(now - ripple.ConfettiStart) / c.Ms;
            foreach (var piece in ripple.ConfettiPieces)
            {
                var d = 20 + MascotEase.Out.Apply(u) * piece.Speed;
                canvas.Save();
                canvas.Translate((float)(cx + d * Math.Cos(piece.Angle) * c.XStretch), (float)(cy + d * Math.Sin(piece.Angle) * c.YStretch));
                canvas.RotateRadians((float)(piece.Rotation + piece.Spin * u));
                particle.Color = Color(ConfettiColors[piece.Color], (1 - u) * 0.85);
                canvas.DrawRect(-3.5f, -0.9f, 7, 1.8f, particle);
                canvas.Restore();
            }
        }
        // 邊緣弧光：只亮 0.32 秒
        var flash = ripple.EdgeFlashAlpha(now, cx);
        if (flash > 0)
        {
            using var glow = Glow(SKColors.White.WithAlpha(230), 5);
            using var stroke = Stroke(WithAlpha(SKColors.White, flash), 1.6);
            stroke.BlendMode = SKBlendMode.Plus;
            stroke.ImageFilter = glow;
            foreach (var (edgeX, side) in new[] { (12.0, 1.0), (CanvasWidth - 12, -1.0) })
            {
                using var path = new SKPathBuilder();
                path.MoveTo((float)(edgeX + side * 10), 8);
                path.QuadTo((float)(edgeX - side * 3), (float)(PanelHeight / 2), (float)(edgeX + side * 10), (float)(PanelHeight - 6));
                canvas.DrawPath(path, stroke);
            }
        }
        canvas.Restore();
    }

    // 角色

    private readonly record struct Hand(double X, double Y, double Z, double S);

    /// <summary>畫角色；回傳實際畫的位置與半徑（特效依它放）</summary>
    public (double X, double Y, double R) DrawHero(MascotFrame frame, SKCanvas canvas)
    {
        var h = frame.Pose;
        double now = frame.Time;
        var R = h[MascotProp.R] * h[MascotProp.Sc];
        if (R < 0.5) return (h[MascotProp.X], h[MascotProp.Y], 0);
        var u = h[MascotProp.R] / 40;
        double swv = Math.Sin(now / 310) * h[MascotProp.Sway], br = Math.Sin(now / 700) * h[MascotProp.Breathe];
        double sx = h[MascotProp.Sx] * (1 - 0.02 * br), sy = h[MascotProp.Sy] * (1 + 0.035 * br), roll = h[MascotProp.Roll] + swv * 0.13;
        var x = h[MascotProp.X] + swv * 7 * u + Math.Sin(now / 17) * h[MascotProp.Shiver] * 1.8 * u;
        var y = h[MascotProp.Y] + Math.Sin(now / 480) * 1.4 * u + h[MascotProp.Jump] * R + R * (1 - sy);
        var yaw = h[MascotProp.Yaw] + frame.GazeYaw * h[MascotProp.Follow] + 0.5 * h[MascotProp.Orbit] * Math.Cos(now / 150);
        var pitch = h[MascotProp.Pitch] + frame.GazePitch * h[MascotProp.Follow] + 0.32 * h[MascotProp.Orbit] * Math.Sin(now / 150);
        var white = Config.Palette.White;
        var look = frame.Look;
        var target = BodyTint(frame);
        var tintT = h[MascotProp.Tint];

        if (h[MascotProp.Glow] > 0)
        {
            var gc = GlowColor(frame);
            var alpha = Math.Min(0.6, Hero.Glow.Alpha * h[MascotProp.Glow] * (look?.GlowScale ?? 1));
            using var shader = SKShader.CreateTwoPointConicalGradient(
                new SKPoint((float)x, (float)y), (float)(R * Hero.Glow.Inner), new SKPoint((float)x, (float)y), (float)(R * Hero.Glow.Outer),
                [Color(gc, alpha), Color(gc, 0)], [0, 1], SKShaderTileMode.Clamp);
            using var paint = new SKPaint { Shader = shader, IsAntialias = true };
            canvas.DrawRect((float)(x - R * 3.3), (float)(y - R * 3.3), (float)(R * 6.6), (float)(R * 6.6), paint);
        }

        void Sphere(double cx, double cy, double r, double alpha = 1)
        {
            if (r <= 0.05) return;
            var t = target is null ? 0 : tintT;
            var to = target ?? (white.Light, white.Mid, white.Shade);
            SKColor[] stops = [Color(Mix(white.Light, to.Light, t), alpha), Color(Mix(white.Mid, to.Mid, t), alpha),
                Color(Mix(white.Shade, to.Shade, t), alpha)];
            var b = Hero.BodyHighlight;
            // 起點的小圓裡面也要塗（canvas 的 createRadialGradient 會塗）：Clamp 就是 drawsBeforeStartLocation
            using var shader = SKShader.CreateTwoPointConicalGradient(
                new SKPoint((float)(cx + b.X * r), (float)(cy + b.Y * r)), (float)(r * 0.04),
                new SKPoint((float)(cx - 0.08 * r), (float)(cy - 0.08 * r)), (float)(r * 1.22),
                stops, [0, 0.52f, 1], SKShaderTileMode.Clamp);
            using var paint = new SKPaint { Shader = shader, IsAntialias = true };
            canvas.DrawOval(Oval(cx, cy, r, r), paint);
        }

        // 手
        var hands = new List<Hand>();
        if (h[MascotProp.Hands] > 0.01)
        {
            (double X, double Y, double Z) l = (h[MascotProp.Lx], h[MascotProp.Ly], h[MascotProp.Lz]);
            (double X, double Y, double Z) r = (h[MascotProp.Rx], h[MascotProp.Ry], h[MascotProp.Rz]);
            if (h[MascotProp.Type] > 0)
            {
                l.Y += Math.Sin(now / 62) * 0.14 * h[MascotProp.Type];
                r.Y += Math.Sin(now / 62 + Math.PI) * 0.14 * h[MascotProp.Type];
            }
            if (h[MascotProp.Wave] > 0)
            {
                var w = Hero.Wave;
                var a = w.Angle + w.Swing * Math.Sin(now * 2 * Math.PI / w.PeriodMs);
                double wx = w.Pivot[0] + w.Radius * Math.Cos(a), wy = w.Pivot[1] + w.Radius * Math.Sin(a);
                r.X += (wx - r.X) * h[MascotProp.Wave];
                r.Y += (wy - r.Y) * h[MascotProp.Wave];
                // 揮手時手不穿過身體：z 固定在前面
                r.Z = Math.Max(r.Z, 0.3);
            }
            if (h[MascotProp.Shiver] > 0)
            {
                l.X += Math.Sin(now / 21) * 0.05 * h[MascotProp.Shiver];
                r.X += Math.Sin(now / 19 + 1) * 0.05 * h[MascotProp.Shiver];
            }
            var k = Hero.Hand.PopFrom + (1 - Hero.Hand.PopFrom) * Math.Min(1, h[MascotProp.Hands]);
            foreach (var p in new[] { l, r }) hands.Add(new Hand(p.X * k, p.Y * k, p.Z, 1 + p.Z * Hero.Hand.DepthScale));
        }
        void DrawHand(Hand p)
        {
            double cx = x + p.X * R * sx, cy = y + p.Y * R * sy;
            var r = R * Hero.Hand.Radius * p.S * Math.Clamp(h[MascotProp.Hands] * 1.3, 0, 1);
            var alpha = Math.Clamp(h[MascotProp.Hands] * 2, 0, 1);
            var drawn = false;
            if (look is { } l && (l.Style.IsEffect() || l.Style == MascotLookStyle.Linear) && tintT > 0.99 && r > 0.05)
            {
                using var layer = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(alpha * 255)) };
                canvas.SaveLayer(layer);
                drawn = MascotLookPainter.DrawHand(l, new SKPoint((float)cx, (float)cy), r, canvas);
                canvas.Restore();
            }
            if (!drawn) Sphere(cx, cy, r, alpha);
        }
        foreach (var p in hands.Where(p => p.Z < 0)) DrawHand(p);

        // 身體（以底部為支點的壓扁已算在 y 裡）
        // 表情：動畫沒有指定眼睛（膠囊）、也沒在睡覺或閉眼時，眼睛與眉毛照平常的表情
        var showsMood = frame.Eyes == MascotEyes.Pill && h[MascotProp.Dash] < 0.5;
        var eyes = showsMood ? frame.Mood.Eyes() ?? MascotEyes.Pill : frame.Eyes;
        var dash = Math.Max(Math.Max(h[MascotProp.Dash], frame.Blink), showsMood ? frame.Mood.Lid() : 0);
        // 外觀的眼睛顏色；null 表示身體已經畫了膠囊眼（LED、像素）。從白色變成外觀的過場中，眼睛顏色跟著混
        var targetEyes = MascotLookPainter.EyesFor(look, R, eyes == MascotEyes.Pill);
        var lookEyes = tintT > 0.99 ? targetEyes
            : new MascotLookPainter.EyeStyle(Mix(MascotLookPainter.Ink, targetEyes?.Color ?? MascotLookPainter.Ink, Math.Max(tintT, 0)), false);
        var ink = Color(lookEyes?.Color ?? MascotLookPainter.Ink);

        canvas.Save();
        canvas.Translate((float)x, (float)y);
        canvas.Scale((float)sx, (float)sy);
        // 格子特效只畫格子（格子之間要看得到背景），過場中先畫漸變的球
        if (look is null || look.Style == MascotLookStyle.Solid || tintT < 0.99) Sphere(0, 0, R);
        if (look is { } bodyLook && bodyLook.Style != MascotLookStyle.Solid && tintT > 0.01)
        {
            // 外觀的身體；過場時從白色漸變過去
            var face = new MascotLookPainter.Face(yaw, pitch, Hero.Eye,
                eyes == MascotEyes.Pill ? h[MascotProp.Open] * (1 - dash) : null);
            using var fade = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(tintT * 255)) };
            if (tintT < 0.99) canvas.SaveLayer(fade);
            MascotLookPainter.DrawBody(bodyLook, R, face, frame.EffectTime, canvas);
            if (tintT < 0.99) canvas.Restore();
        }
        canvas.Restore();

        // 臉：依 yaw／pitch 投影到球面
        double cr = Math.Cos(roll), sr = Math.Sin(roll);
        (double X, double Y, double A, double Fx, double Fy)? Project(double ye, double pe)
        {
            var cz = Math.Cos(ye) * Math.Cos(pe);
            if (cz <= 0.05) return null;
            double ex = Math.Sin(ye) * Math.Cos(pe) * R * sx, ey = -Math.Sin(pe) * R * sy;
            return (x + ex * cr - ey * sr, y + ex * sr + ey * cr, Math.Clamp((cz - 0.05) / 0.25, 0, 1),
                Math.Max(0.2, Math.Abs(Math.Cos(ye))), Math.Max(0.2, Math.Cos(pe)));
        }
        var blush = Math.Max(h[MascotProp.Blush], look?.Blush == true ? 0.9 * tintT : 0);
        if (blush > 0.01)
        {
            foreach (var s in new[] { -1.0, 1.0 })
            {
                if (Project(yaw + s * 0.52, pitch - 0.32) is not { } p) continue;
                canvas.Save();
                canvas.Translate((float)p.X, (float)p.Y);
                canvas.RotateRadians((float)roll);
                using var paint = Fill(Rgba(1, 0.47, 0.59, 0.55 * blush * p.A));
                canvas.DrawOval(Oval(0, 0, R * 0.17 * p.Fx, R * 0.09), paint);
                canvas.Restore();
            }
        }
        if (showsMood && frame.Mood.Brow() != MascotBrow.None)
        {
            var b = Hero.Brow;
            var tilt = frame.Mood.Brow() switch
            {
                MascotBrow.Worried => b.WorriedTilt,
                MascotBrow.Sad => b.SadTilt,
                _ => 0.0,
            };
            var lift = frame.Mood.Brow() == MascotBrow.Raised ? 0.1 : 0;
            foreach (var s in new[] { -1.0, 1.0 })
            {
                if (Project(yaw + s * b.Yaw, pitch + Hero.Eye.Pitch + b.Pitch + lift) is not { } p) continue;
                canvas.Save();
                canvas.Translate((float)p.X, (float)p.Y);
                canvas.RotateRadians((float)(roll + s * tilt));
                var w = R * b.Width * p.Fx;
                using var paint = Stroke(WithAlpha(ink, p.A), R * b.Thickness);
                canvas.DrawLine((float)(-w / 2), 0, (float)(w / 2), 0, paint);
                canvas.Restore();
            }
        }
        if (lookEyes is not null)
        {
            foreach (var s in new[] { -1.0, 1.0 })
            {
                if (Project(yaw + s * Hero.Eye.Yaw, pitch + Hero.Eye.Pitch) is not { } p) continue;
                canvas.Save();
                canvas.Translate((float)p.X, (float)p.Y);
                canvas.RotateRadians((float)roll);
                var color = WithAlpha(ink, p.A);
                // ASCII、線框、霓虹的眼睛會發光
                using var glow = lookEyes.Glow ? Glow(color, R * 0.15) : null;
                using var fill = Fill(color);
                fill.ImageFilter = glow;
                switch (eyes)
                {
                    case MascotEyes.Pill:
                    {
                        var w = R * Hero.Eye.Width * p.Fx * (1 + 0.55 * dash);
                        var hh = (R * Hero.Eye.Height * h[MascotProp.Open] * (1 - dash) + R * 0.13 * dash) * p.Fy;
                        var height = Math.Max(hh, R * 0.1);
                        canvas.Translate(0, (float)(dash * R * 0.1));
                        var corner = (float)(Math.Min(w, height) / 2);
                        canvas.DrawRoundRect(new SKRect((float)(-w / 2), (float)(-height / 2), (float)(w / 2), (float)(height / 2)), corner, corner, fill);
                        break;
                    }
                    case MascotEyes.Happy:
                    {
                        var w = R * 0.16 * p.Fx;
                        using var path = new SKPathBuilder();
                        path.MoveTo((float)-w, (float)(R * 0.06));
                        path.QuadTo(0, (float)(-R * 0.2), (float)w, (float)(R * 0.06));
                        using var stroke = Stroke(color, R * 0.12);
                        stroke.ImageFilter = glow;
                        canvas.DrawPath(path, stroke);
                        break;
                    }
                    case MascotEyes.Dot:
                    {
                        // 表情（擔心、驚訝）的小圓點比嚇到時大一點，迷你角色上也看得到
                        var k = showsMood ? 0.13 : 0.1;
                        canvas.DrawOval(Oval(0, 0, R * k * p.Fx, R * k * p.Fy), fill);
                        break;
                    }
                    case MascotEyes.Xx:
                    {
                        var w = R * 0.12 * p.Fx;
                        using var path = new SKPathBuilder();
                        path.MoveTo((float)(-s * w), (float)(-R * 0.13));
                        path.LineTo((float)(s * w), 0);
                        path.LineTo((float)(-s * w), (float)(R * 0.13));
                        using var stroke = Stroke(color, R * 0.1);
                        stroke.ImageFilter = glow;
                        canvas.DrawPath(path, stroke);
                        break;
                    }
                    case MascotEyes.Cross:
                    {
                        double w = R * 0.11 * p.Fx, hh = R * 0.11 * p.Fy;
                        using var path = new SKPathBuilder();
                        path.MoveTo((float)-w, (float)-hh);
                        path.LineTo((float)w, (float)hh);
                        path.MoveTo((float)-w, (float)hh);
                        path.LineTo((float)w, (float)-hh);
                        using var stroke = Stroke(color, R * 0.085);
                        stroke.ImageFilter = glow;
                        canvas.DrawPath(path, stroke);
                        break;
                    }
                    case MascotEyes.Spiral:
                    {
                        canvas.RotateRadians((float)(now / 110 * s));
                        using var path = new SKPathBuilder();
                        for (var t = 0.0; t < 9.4; t += 0.25)
                        {
                            var r = R * (0.015 + t * 0.021);
                            var point = new SKPoint((float)(r * Math.Cos(t) * p.Fx), (float)(r * Math.Sin(t)));
                            if (t == 0) path.MoveTo(point); else path.LineTo(point);
                        }
                        using var stroke = Stroke(color, R * 0.065);
                        stroke.ImageFilter = glow;
                        canvas.DrawPath(path, stroke);
                        break;
                    }
                }
                canvas.Restore();
            }
        }

        // 工作中的鍵盤：淺灰底、上緣淡白亮線、一排深灰按鍵輪流亮成光暈色（shared/mascot-anim.json hero.keyboard）
        if (h[MascotProp.Kb] > 0.01)
        {
            var k = Config.Hero.Keyboard;
            double kx = x, ky = y + R * k.Y * sy, kw = R * k.Width, kh = R * k.Height;
            var opacity = h[MascotProp.Kb];
            using (var paint = Fill(Color(MascotConfig.Rgb(k.Color), opacity)))
            {
                canvas.DrawRoundRect(new SKRect((float)(kx - kw / 2), (float)(ky - kh / 2), (float)(kx + kw / 2), (float)(ky + kh / 2)),
                    (float)(kh / 2), (float)(kh / 2), paint);
            }
            using (var paint = Fill(WithAlpha(SKColors.White, k.Shine.Alpha * opacity)))
            {
                canvas.DrawRect((float)(kx + kw * k.Shine.X), (float)(ky + kh * k.Shine.Y), (float)(kw * k.Shine.Width), (float)(kh * k.Shine.Height), paint);
            }
            var keyColor = Color(MascotConfig.Rgb(k.Keys.Color), opacity);
            var lit = Color(look?.Glow ?? frame.Character.Tint(Config.Palette).Glow, opacity);
            using var key = Fill(keyColor);
            for (var i = 0; i < k.Keys.Count; i++)
            {
                var on = Math.Sin(now / 62 + i * k.Keys.Phase) > k.Keys.OnAbove;
                key.Color = on ? lit : keyColor;
                canvas.DrawRect((float)(kx + kw * (k.Keys.X + i * k.Keys.Step)), (float)(ky + kh * k.Keys.Y),
                    (float)(kw * k.Keys.Width), (float)(kh * k.Keys.Height), key);
            }
        }

        foreach (var p in hands.Where(p => p.Z >= 0)) DrawHand(p);

        // 生病：頭的右上方冒一滴冷汗（形狀，不只靠顏色）
        if (showsMood && frame.Mood.Sweat() && R > 4)
        {
            double cx = x + R * 0.8 * sx, cy = y - R * 0.42 * sy, s = R * 0.13;
            using var drop = new SKPathBuilder();
            drop.MoveTo((float)cx, (float)(cy - s * 1.6));
            drop.QuadTo((float)(cx + s * 0.9), (float)(cy - s * 0.6), (float)(cx + s), (float)(cy + s * 0.2));
            drop.ArcTo(Oval(cx, cy + s * 0.2, s, s), 0, 180, false);
            drop.QuadTo((float)(cx - s * 0.9), (float)(cy - s * 0.6), (float)cx, (float)(cy - s * 1.6));
            using var paint = Fill(Rgba(0.62, 0.82, 1));
            canvas.DrawPath(drop, paint);
        }
        return (x, y, R);
    }

    // 特效

    private static readonly SKColor Yellow = new(0xFF, 0xD2, 0x5E);
    private static readonly SKColor ZColor = Rgba(0.85, 0.85, 0.89);

    public void DrawEffects(MascotFrame frame, (double X, double Y, double R) placed, SKCanvas canvas)
    {
        var (x, y, R) = placed;
        if (R < 2) return;
        double now = frame.Time;
        if (frame.Eyes == MascotEyes.Spiral && R > 5)
        {
            for (var i = 0; i < 3; i++)
            {
                var a = now / 260 + i * 2.094;
                DrawStar(x + Math.Cos(a) * R * 0.95, y - R * 1.15 + Math.Sin(a) * R * 0.22, R * 0.15, canvas);
            }
        }
        if (frame.ThinkingDots is { } litCount)
        {
            // 思考泡泡：右上方三個小點依序亮起；亮的用角色的淺色（特效外觀用主色），暗的用半透明白
            var on = Color(ThinkingColor(frame));
            using var paint = Fill(on);
            for (var i = 0; i < 3; i++)
            {
                var r = R * 0.128;
                paint.Color = i < litCount ? on : WithAlpha(SKColors.White, 0.22);
                canvas.DrawOval(Oval(x + R * 0.95 + i * R * 0.367, y - R * 0.95, r, r), paint);
            }
        }
        // z 用三段線畫（每格排版文字太花 CPU，睡著時一直在重畫）
        if (frame.Dozing)
        {
            var rise = frame.DozeRise ?? 0;
            // 飄起時淡入淡出；靜止時停在原處
            var alpha = frame.DozeRise is { } d ? Math.Sin(d * Math.PI) * 0.85 : 0.85;
            DrawZ(x + R * (0.95 + rise * 0.4), y - R * (0.45 + rise * 0.4), Math.Max(R * 0.55, 5), alpha, canvas);
        }
        if (frame.Sleeping)
        {
            for (var i = 0; i < 3; i++)
            {
                var u = (now / 1000 + i * 0.8) % 2.4 / 2.4;
                DrawZ(x + R * 0.75 + u * R * 0.5, y - R * 0.5 - u * R, R * (0.24 + i * 0.075), Math.Sin(u * Math.PI) * 0.85, canvas);
            }
        }
        foreach (var effect in frame.Effects)
        {
            if (effect.Progress(frame.Time) is not { } u) continue;
            switch (effect.Kind)
            {
                case MascotEffectKind.Ring ring:
                {
                    var r = R * (1.1 + MascotEase.Out.Apply(u) * 1.9);
                    using var paint = Stroke(Color(StatusColor(ring.Level), (1 - u) * 0.9), 2.4 * (1 - u) + 0.4, round: false);
                    canvas.DrawOval(Oval(x, y, r, r), paint);
                    break;
                }
                case MascotEffectKind.Heart:
                    DrawHeart(x + R * 0.95, y - R * 0.7 - u * R, R * 0.22 * (0.6 + 0.4 * Math.Min(1, u * 4)), 1 - u, canvas);
                    break;
                case MascotEffectKind.Bang:
                {
                    var alpha = u < 0.8 ? 1 : (1 - u) / 0.2;
                    var k = Math.Min(1, u * 6);
                    DrawBang(x + R * 0.85, y - R * 0.7 - k * 4, R * 0.62, alpha, canvas);
                    DrawBang(x + R * 1.15, y - R * 0.92 - k * 4, R * 0.45, alpha, canvas);
                    break;
                }
            }
        }
    }

    private static SKTypeface? bangFace;

    /// <summary>「!」：左下角（文字框的底）在 (x, y)，同 SwiftUI 的 anchor: .bottomLeading</summary>
    private static void DrawBang(double x, double y, double size, double alpha, SKCanvas canvas)
    {
        bangFace ??= SKTypeface.FromFamilyName("Segoe UI", SKFontStyleWeight.SemiBold, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright)
            ?? SKTypeface.Default;
        using var font = new SKFont(bangFace, (float)size);
        using var paint = Fill(WithAlpha(Yellow, alpha));
        canvas.DrawText("!", (float)x, (float)(y - font.Metrics.Descent), SKTextAlign.Left, font, paint);
    }

    /// <summary>「z」：左下角在 (x, y)，高 size</summary>
    private static void DrawZ(double x, double y, double s, double alpha, SKCanvas canvas)
    {
        using var path = new SKPathBuilder();
        path.MoveTo((float)x, (float)(y - s));
        path.LineTo((float)(x + s * 0.8), (float)(y - s));
        path.LineTo((float)x, (float)y);
        path.LineTo((float)(x + s * 0.8), (float)y);
        using var paint = Stroke(WithAlpha(ZColor, alpha), Math.Max(s * 0.17, 0.9));
        canvas.DrawPath(path, paint);
    }

    private static void DrawStar(double cx, double cy, double s, SKCanvas canvas)
    {
        using var path = new SKPathBuilder();
        for (var i = 0; i < 10; i++)
        {
            double r = i % 2 == 1 ? s * 0.45 : s, a = i * Math.PI / 5 - Math.PI / 2;
            var p = new SKPoint((float)(cx + r * Math.Cos(a)), (float)(cy + r * Math.Sin(a)));
            if (i == 0) path.MoveTo(p); else path.LineTo(p);
        }
        path.Close();
        using var paint = Fill(Yellow);
        canvas.DrawPath(path, paint);
    }

    private static void DrawHeart(double cx, double cy, double s, double alpha, SKCanvas canvas)
    {
        using var path = new SKPathBuilder();
        path.MoveTo((float)cx, (float)(cy + s * 0.9));
        path.CubicTo((float)(cx - s * 1.4), (float)cy, (float)(cx - s * 0.9), (float)(cy - s * 1.1), (float)cx, (float)(cy - s * 0.35));
        path.CubicTo((float)(cx + s * 0.9), (float)(cy - s * 1.1), (float)(cx + s * 1.4), (float)cy, (float)cx, (float)(cy + s * 0.9));
        using var paint = Fill(new SKColor(0xFF, 0x6B, 0x8A).WithAlpha((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255)));
        canvas.DrawPath(path, paint);
    }
}

internal static class SkiaPaths
{
    /// <summary>畫完就丟的路徑（SkiaSharp 4 起 SKPath 不能再修改，先用 SKPathBuilder 組好）</summary>
    public static void DrawPath(this SKCanvas canvas, SKPathBuilder builder, SKPaint paint)
    {
        using var path = builder.Snapshot();
        canvas.DrawPath(path, paint);
    }
}
