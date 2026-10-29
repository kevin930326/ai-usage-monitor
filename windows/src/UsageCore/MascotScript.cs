namespace AIUsageMonitor.Core;

// 角色的姿勢（ADR-0016 第 1 節）：畫面是「狀態＋時間＋種子」的純函式。和 Mac 的 UsageKit/MascotScript.swift
// 是同一份規則，fixtures/mascot-director 的 golden 兩邊比對；改規則時兩邊一起改。
// 每一段（過場、展開、收合、每個動畫、回位、模式姿勢）是一份腳本：起始姿勢＋依時間排列的補間，任一時間點的姿勢
// 都可以直接算出來，不保存「進行到哪」。換下一段時，以上一段在那一刻的姿勢當新腳本的起點。

/// <summary>姿勢的每個參數（名稱同 notch-demo.html 的 hero；順序同 Swift 的 MascotProp）</summary>
public enum MascotProp
{
    X, Y, R, Sc, Yaw, Pitch, Roll, Open, Dash, Hands, Wave, Sway, Tint, Dot, Glow, Follow,
    Sx, Sy, Jump, Orbit, Shiver, Blush, Type, Kb, Breathe,
    Lx, Ly, Lz, Rx, Ry, Rz,
}

/// <summary>一組姿勢參數（值型別的語意：With 回傳新的一份）</summary>
public sealed class MascotPose : IEquatable<MascotPose>
{
    public static readonly MascotProp[] AllProps = Enum.GetValues<MascotProp>();

    private readonly double[] values;

    public MascotPose() => values = new double[AllProps.Length];

    public MascotPose(IReadOnlyDictionary<MascotProp, double> pairs) : this()
    {
        foreach (var (prop, value) in pairs) values[(int)prop] = value;
    }

    private MascotPose(double[] values) => this.values = values;

    public double this[MascotProp prop] => values[(int)prop];

    public MascotPose With(IReadOnlyDictionary<MascotProp, double> pairs)
    {
        var copy = (double[])values.Clone();
        foreach (var (prop, value) in pairs) copy[(int)prop] = value;
        return new MascotPose(copy);
    }

    public MascotPose With(MascotProp prop, double value) => With(new Dictionary<MascotProp, double> { [prop] = value });

    public IReadOnlyList<double> Values => values;

    public bool Equals(MascotPose? other) => other is not null && values.AsSpan().SequenceEqual(other.values);
    public override bool Equals(object? obj) => obj is MascotPose other && Equals(other);
    public override int GetHashCode() => values.Aggregate(0, (hash, value) => HashCode.Combine(hash, value));
}

/// <summary>緩動曲線（同 demo 的 EO、EIO、EIN、EXP、BACK、BACKS）</summary>
public enum MascotEase { Linear, Out, InOut, InCubic, ExpoOut, Back, BackSoft }

public static class MascotEasing
{
    public static double Apply(this MascotEase ease, double t)
    {
        t = Math.Clamp(t, 0, 1);
        return ease switch
        {
            MascotEase.Linear => t,
            MascotEase.Out => 1 - Math.Pow(1 - t, 3),
            MascotEase.InOut => t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2,
            MascotEase.InCubic => t * t * t,
            MascotEase.ExpoOut => t >= 1 ? 1 : 1 - Math.Pow(2, -10 * t),
            MascotEase.Back => Back(t, 1.7),
            MascotEase.BackSoft => Back(t, 1.0),
            _ => t,
        };
    }

    private static double Back(double t, double c) => 1 + (c + 1) * Math.Pow(t - 1, 3) + c * Math.Pow(t - 1, 2);
}

/// <summary>眼睛樣式（閉眼「– –」以 Dash 參數表示，不是另一種樣式）；Cross 是 ×（額度用完）</summary>
public enum MascotEyes { Pill, Happy, Dot, Xx, Spiral, Cross }

/// <summary>角色身邊的小特效：愛心、驚嘆號、額度提醒推出的光環（Level 0 正常、1 偏高、2 用完）</summary>
public abstract record MascotEffectKind
{
    public sealed record Heart : MascotEffectKind;
    public sealed record Bang : MascotEffectKind;
    public sealed record Ring(int Level) : MascotEffectKind;
}

/// <summary>特效：Start 是絕對時間（ms）</summary>
public sealed record MascotEffect(MascotEffectKind Kind, long Start, int Duration)
{
    public double? Progress(long time) =>
        time >= Start && time < Start + Duration ? (double)(time - Start) / Duration : null;
}

/// <summary>一段腳本：起點（絕對時間）、起始姿勢與眼睛、之後的補間、換眼睛的時間點與特效</summary>
public sealed class MascotScript
{
    public readonly record struct Tween(int At, MascotProp Prop, double To, int Duration, MascotEase Ease);

    private List<Tween> tweens = [];
    private List<(int At, MascotEyes Eyes)> eyes = [];
    private readonly List<MascotEffect> effects = [];

    public MascotScript(long start, MascotPose basePose, MascotEyes baseEyes = MascotEyes.Pill)
    {
        Start = start;
        Base = basePose;
        BaseEyes = baseEyes;
    }

    public long Start { get; }
    public MascotPose Base { get; }
    public MascotEyes BaseEyes { get; private set; }
    public IReadOnlyList<Tween> Tweens => tweens;
    public IReadOnlyList<MascotEffect> Effects => effects;

    /// <summary>和 demo 的 to({...}, dur, ease) 一樣：at 是從這段開始算的毫秒；同一個參數後來的補間取代先前的。
    /// 依參數的列舉順序加入（同 Swift）</summary>
    public void To(IReadOnlyDictionary<MascotProp, double> pairs, int duration, MascotEase ease = MascotEase.Out, int at = 0)
    {
        foreach (var prop in MascotPose.AllProps)
        {
            if (pairs.TryGetValue(prop, out var value))
                tweens.Add(new Tween(at, prop, value, Math.Max(duration, 1), ease));
        }
    }

    public void SetEyes(MascotEyes style, int at = 0)
    {
        if (at <= 0 && eyes.Count == 0) BaseEyes = style;
        else eyes.Add((at, style));
    }

    public void Effect(MascotEffectKind kind, int duration, int at = 0) => effects.Add(new MascotEffect(kind, Start + at, duration));

    /// <summary>某個參數在 time（絕對時間）的值：依時間順序走過這個參數的補間，每一段從前一段在它開始時的值出發</summary>
    public double Value(MascotProp prop, long time)
    {
        var local = time - Start;
        Tween? activeTween = null;
        double activeFrom = 0;
        foreach (var tween in tweens)
        {
            if (tween.Prop != prop) continue;
            if (tween.At > local) break;
            var from = activeTween is { } previous ? Evaluate(previous, activeFrom, tween.At) : Base[prop];
            activeTween = tween;
            activeFrom = from;
        }
        return activeTween is { } active ? Evaluate(active, activeFrom, local) : Base[prop];
    }

    private static double Evaluate(Tween tween, double from, long local)
    {
        var u = (double)(local - tween.At) / tween.Duration;
        return from + (tween.To - from) * tween.Ease.Apply(u);
    }

    public MascotPose Pose(long time)
    {
        var pairs = new Dictionary<MascotProp, double>();
        foreach (var prop in MascotPose.AllProps) pairs[prop] = Value(prop, time);
        return new MascotPose(pairs);
    }

    public MascotEyes Eyes(long time)
    {
        var local = time - Start;
        for (var i = eyes.Count - 1; i >= 0; i--)
        {
            if (eyes[i].At <= local) return eyes[i].Eyes;
        }
        return BaseEyes;
    }

    /// <summary>這段的補間全部結束的時間（絕對時間）；之後姿勢不再變（持續的晃動、呼吸由參數乘上時間函式，另外計算）</summary>
    public long SettledAt
    {
        get
        {
            var last = tweens.Count == 0 ? 0 : tweens.Max(t => t.At + t.Duration);
            var lastEyes = eyes.Count == 0 ? 0 : eyes.Max(e => e.At);
            return Start + Math.Max(last, lastEyes);
        }
    }

    /// <summary>依時間排序補間（To 可以不依時間順序呼叫）；同時間的保持加入的順序（穩定排序，同 Swift）</summary>
    public void FinalizeOrder()
    {
        tweens = tweens.Select((tween, index) => (tween, index)).OrderBy(p => p.tween.At).ThenBy(p => p.index)
            .Select(p => p.tween).ToList();
        eyes = eyes.OrderBy(e => e.At).ToList();
    }
}
