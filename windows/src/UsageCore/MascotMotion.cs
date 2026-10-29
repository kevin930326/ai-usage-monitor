namespace AIUsageMonitor.Core;

// 面板的彈簧、外形、鼓一下、固定種子的亂數與過場的漣漪粒子。和 Mac 的 UsageKit/MascotPanelMotion.swift、
// MascotParticles.swift 是同一份算法，fixtures/mascot-director 的 golden 兩邊比對。

/// <summary>面板大小的彈簧（MASCOT-SPEC 第 3 節）：用解析解，任一時間點的進度都能直接算出來（截圖可以指定時間）</summary>
public readonly record struct MascotSpring(double Target, long Start, double Position, double Velocity, double Stiffness, double DampingRatio)
{
    /// <summary>靜止在某個位置</summary>
    public static MascotSpring Resting(double position) => new(position, 0, position, 0, 1, 1);

    /// <summary>(位置, 速度)；時間以毫秒計，速度以「每秒」計</summary>
    public (double Position, double Velocity) State(long time)
    {
        var t = Math.Max(time - Start, 0) / 1000.0;
        double x0 = Position - Target, v0 = Velocity;
        double w = Math.Sqrt(Stiffness), z = DampingRatio;
        double x, v;
        if (z < 1)
        {
            var wd = w * Math.Sqrt(1 - z * z);
            var decay = Math.Exp(-z * w * t);
            var b = (v0 + z * w * x0) / wd;
            x = decay * (x0 * Math.Cos(wd * t) + b * Math.Sin(wd * t));
            v = decay * (-z * w * (x0 * Math.Cos(wd * t) + b * Math.Sin(wd * t)) + (-x0 * wd * Math.Sin(wd * t) + b * wd * Math.Cos(wd * t)));
        }
        else
        {
            var decay = Math.Exp(-w * t);
            var b = v0 + w * x0;
            x = (x0 + b * t) * decay;
            v = (b - w * (x0 + b * t)) * decay;
        }
        // 和 demo 一樣：夠接近就停在終點
        if (Math.Abs(x) < 0.0005 && Math.Abs(v) < 0.001) return (Target, 0);
        return (Target + x, v);
    }

    public bool IsSettled(long time)
    {
        var s = State(time);
        return s.Position == Target && s.Velocity == 0;
    }

    /// <summary>從 time 的位置與速度出發、往新的目標</summary>
    public MascotSpring Retarget(double newTarget, long time, double stiffness, double dampingRatio)
    {
        var s = State(time);
        return new MascotSpring(newTarget, time, s.Position, s.Velocity, stiffness, dampingRatio);
    }
}

/// <summary>面板某一刻的外形（demo 的 frame()）；MiniOpacity 是迷你角色與迷你圓環的透明度</summary>
public readonly record struct MascotPanelShape(double Width, double Height, double Corner, double MiniOpacity, double Progress)
{
    public static MascotPanelShape From(double progress, double bump, MascotPanelConfig panel)
    {
        var c = panel.Collapsed;
        var e = panel.Expanded;
        return new MascotPanelShape(
            c.Width + panel.AlertBump.Width * bump + (e.Width - c.Width) * progress,
            c.Height + panel.AlertBump.Height * bump + (e.Height - c.Height) * progress,
            c.Corner + (e.Corner - c.Corner) * Math.Min(panel.CornerOvershootMax, progress),
            Math.Clamp(1 - progress * panel.MiniFadeFactor, 0, 1),
            progress);
    }
}

/// <summary>收合時的提醒：面板往外鼓一下，一段時間後收回</summary>
public static class MascotBump
{
    public static double Value(long time, long? start, MascotPanelConfig panel)
    {
        if (start is not { } s || time < s) return 0;
        var b = panel.AlertBump;
        var local = time - s;
        var rise = MascotEase.Back.Apply((double)local / b.RiseMs);
        if (local < b.HoldMs) return rise;
        var fall = MascotEase.InOut.Apply((double)(local - b.HoldMs) / b.FallMs);
        return rise * (1 - fall);
    }

    public static bool IsActive(long time, long? start, MascotPanelConfig panel) =>
        start is { } s && time >= s && time < s + panel.AlertBump.HoldMs + panel.AlertBump.FallMs;
}

/// <summary>固定種子的亂數（SplitMix64）：粒子、碎片與眨眼的時間由種子決定，同一個種子每次畫出一樣的畫面</summary>
public struct MascotRandom(ulong seed)
{
    private ulong state = seed;

    public ulong Next()
    {
        unchecked
        {
            state += 0x9E3779B97F4A7C15;
            var z = state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }
    }

    /// <summary>[0, 1)</summary>
    public double Unit() => (Next() >> 11) / (double)(1UL << 53);

    /// <summary>近似高斯（三個均勻亂數相加，同 demo 的 gs()），約 -1～1</summary>
    public double Gaussian() => (Unit() + Unit() + Unit() - 1.5) / 1.5;

    /// <summary>由種子與編號算出的一次性亂數（眨眼、第 n 圈漣漪）</summary>
    public static double Unit(ulong seed, ulong index)
    {
        var random = new MascotRandom(seed ^ unchecked(index * 0xD6E8FEB86659FD93));
        return random.Unit();
    }
}

/// <summary>過場的漣漪粒子與碎片（MASCOT-SPEC 第 4 節）</summary>
public sealed class MascotRipple
{
    public readonly record struct Particle(double Angle, double Jitter, double Size, double Phase, bool Tinted);
    public sealed record Ring(int Index, long Start, IReadOnlyList<Particle> Particles, double Seed);
    public readonly record struct Confetti(double Angle, double Speed, double Rotation, double Spin, int Color);

    public MascotRipple(MascotRippleConfig config, long introStart, IReadOnlyList<int> ringsAt, int confettiAt, ulong seed)
    {
        Config = config;
        var random = new MascotRandom(seed);
        var rings = new List<Ring>();
        for (var index = 0; index < ringsAt.Count; index++)
        {
            var particles = new Particle[config.Particles];
            for (var i = 0; i < particles.Length; i++)
            {
                var angle = random.Unit() * 2 * Math.PI;
                var jitter = random.Gaussian() * config.ThicknessPx;
                var size = random.Unit() * 1.1 + 0.45;
                var phase = random.Unit() * 2 * Math.PI;
                var tinted = random.Unit() < config.TintFraction;
                particles[i] = new Particle(angle, jitter, size, phase, tinted);
            }
            rings.Add(new Ring(index, introStart + ringsAt[index], particles, random.Unit() * 9));
        }
        Rings = rings;
        var confetti = new Confetti[config.Confetti.Count];
        for (var n = 0; n < confetti.Length; n++)
        {
            var angle = random.Unit() * 2 * Math.PI;
            var speed = config.Confetti.SpeedMin + random.Unit() * config.Confetti.SpeedSpan;
            var rotation = random.Unit() * 6;
            var spin = (random.Unit() - 0.5) * 8;
            confetti[n] = new Confetti(angle, speed, rotation, spin, n % 5);
        }
        ConfettiPieces = confetti;
        ConfettiStart = introStart + confettiAt;
    }

    public MascotRippleConfig Config { get; }
    public IReadOnlyList<Ring> Rings { get; }
    public IReadOnlyList<Confetti> ConfettiPieces { get; }
    public long ConfettiStart { get; }

    /// <summary>某一圈在 time 的半徑與透明度；不在播放時間內為 null</summary>
    public (double Radius, double Fade)? RingState(Ring ring, long time)
    {
        if (time < ring.Start) return null;
        var u = (double)(time - ring.Start) / Config.DurationMs;
        if (u >= 1) return null;
        var radius = Config.RadiusFrom + MascotEase.Out.Apply(u) * Config.RadiusSpan;
        var fade = (u < Config.FadeIn ? u / Config.FadeIn : 1) * (1 - u * u * 0.7);
        return (radius, fade);
    }

    /// <summary>前兩圈碰到面板左右邊緣（距中心 halfWidth - hitInset）的時間；碰不到為 null</summary>
    public long? EdgeHitTime(Ring ring, double halfWidth)
    {
        if (ring.Index >= Config.EdgeFlash.Rings) return null;
        var needed = (halfWidth - Config.EdgeFlash.HitInsetPx - Config.RadiusFrom) / Config.RadiusSpan;
        if (needed >= 1) return null;
        // EO(u) = 1 - (1-u)^3 = needed
        var u = needed <= 0 ? 0 : 1 - Math.Pow(1 - needed, 1.0 / 3.0);
        return ring.Start + (long)Math.Ceiling(u * Config.DurationMs);
    }

    /// <summary>邊緣弧光在 time 的透明度</summary>
    public double EdgeFlashAlpha(long time, double halfWidth)
    {
        var alpha = 0.0;
        foreach (var ring in Rings)
        {
            if (EdgeHitTime(ring, halfWidth) is not { } hit || time < hit || time >= hit + Config.EdgeFlash.Ms) continue;
            var strength = ring.Index < Config.EdgeFlash.Alpha.Length ? Config.EdgeFlash.Alpha[ring.Index] : 0;
            alpha = Math.Max(alpha, Math.Sin((double)(time - hit) / Config.EdgeFlash.Ms * Math.PI) * strength);
        }
        return alpha;
    }

    /// <summary>粒子、碎片都播完的時間</summary>
    public long EndTime => Math.Max(Rings.Count == 0 ? 0 : Rings.Max(r => r.Start + Config.DurationMs), ConfettiStart + Config.Confetti.Ms);
}
