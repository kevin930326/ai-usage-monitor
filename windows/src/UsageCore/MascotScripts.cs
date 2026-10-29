using P = AIUsageMonitor.Core.MascotProp;

namespace AIUsageMonitor.Core;

// 各段腳本與表情（數值同 notch-demo.html；位置、時間取自 MascotConfig）。和 Mac 的 UsageKit/MascotScripts.swift、
// MascotExpressions.swift 是同一份腳本，fixtures/mascot-director 的 golden 兩邊比對；改腳本時兩邊一起改。
// 每個函式只描述「從 basePose 開始、之後怎麼動」，起點姿勢由呼叫端以上一段在那一刻的姿勢傳入。

public sealed class MascotScripts(MascotConfig config)
{
    public MascotConfig Config { get; } = config;

    private MascotHeroConfig Hero => Config.Hero;

    private static Dictionary<P, double> D(params (P Prop, double Value)[] pairs) => pairs.ToDictionary(p => p.Prop, p => p.Value);

    private static Dictionary<P, double> Merge(Dictionary<P, double> a, IReadOnlyDictionary<P, double> b)
    {
        var merged = new Dictionary<P, double>(a);
        foreach (var (prop, value) in b) merged[prop] = value;
        return merged;
    }

    /// <summary>休息時的手（REST）</summary>
    public Dictionary<P, double> RestHands
    {
        get
        {
            var l = Hero.HandRest.Left;
            var r = Hero.HandRest.Right;
            return D((P.Lx, l[0]), (P.Ly, l[1]), (P.Lz, l[2]), (P.Rx, r[0]), (P.Ry, r[1]), (P.Rz, r[2]));
        }
    }

    /// <summary>收合時的姿勢：迷你角色（close 的終點；App 啟動時直接用這個）</summary>
    public MascotPose CollapsedPose =>
        new MascotPose(D((P.X, Hero.Mini.X), (P.Y, Hero.Mini.Y), (P.R, Hero.Mini.Radius), (P.Sc, 1), (P.Open, 1), (P.Tint, 1),
            (P.Dot, 1), (P.Follow, 1), (P.Sx, 1), (P.Sy, 1))).With(RestHands);

    /// <summary>展開後角色卡上的靜止姿勢（截圖與「關閉過場」時的終點）</summary>
    public MascotPose CardPose =>
        CollapsedPose.With(D((P.X, Hero.Card.X), (P.Y, Hero.Card.Y), (P.R, Hero.Card.Radius), (P.Glow, 0.5)));

    // MARK: 過場（MASCOT-SPEC 第 4 節）

    public MascotScript Intro(long start)
    {
        var place = Hero.Intro;
        var basePose = new MascotPose(D((P.X, place.X), (P.Y, place.Y + place.StartDrop), (P.R, place.Radius), (P.Sc, 0),
            (P.Pitch, Config.Intro.StartPitch), (P.Open, 1), (P.Dash, 1), (P.Sx, 1), (P.Sy, 1))).With(RestHands).With(P.Tint, 0);
        var s = new MascotScript(start, basePose);
        s.To(D((P.Sc, 1)), 560, MascotEase.Back);
        s.To(D((P.Glow, 1)), 600);
        s.To(D((P.Y, place.Y)), 760, MascotEase.Out, at: 100);
        s.To(D((P.Pitch, 0)), 880, MascotEase.BackSoft, at: 100);
        s.To(D((P.Dash, 0)), 170, at: 950);
        s.To(D((P.Yaw, -0.38), (P.Roll, -0.05)), 300, MascotEase.InOut, at: 1150);
        s.To(D((P.Yaw, 0.32), (P.Roll, 0.05)), 340, MascotEase.InOut, at: 1480);
        s.To(D((P.Yaw, 0), (P.Roll, 0)), 260, MascotEase.InOut, at: 1850);
        s.To(D((P.Pitch, -0.5)), 220, MascotEase.InOut, at: 2100);
        s.To(D((P.Hands, 1)), 440, MascotEase.Back, at: 2100);
        s.To(D((P.Pitch, 0.2), (P.Yaw, -0.22)), 360, MascotEase.InOut, at: 2320);
        s.To(D((P.Wave, 1)), 200, at: 2320);
        s.To(D((P.Sway, 0.8)), 300, at: 2320);
        s.SetEyes(MascotEyes.Happy, at: 2500);
        s.SetEyes(MascotEyes.Pill, at: 3300);
        s.To(D((P.Wave, 0)), 200, at: 3750);
        s.To(D((P.Sway, 0)), 360, at: 3750);
        s.To(D((P.Dash, 1)), 80, MascotEase.InCubic, at: 3750);
        s.To(D((P.Dash, 0)), 130, at: 3870);
        s.To(D((P.Hands, 0)), 320, MascotEase.InCubic, at: 3980);
        s.To(D((P.Tint, 1)), 520, at: 3980);
        s.To(D((P.Dot, 1)), 380, at: 3980);
        s.To(D((P.Pitch, 0), (P.Yaw, 0)), 320, MascotEase.InOut, at: 3980);
        s.To(D((P.X, Hero.Card.X), (P.Y, Hero.Card.Y), (P.R, Hero.Card.Radius)), 760, MascotEase.ExpoOut, at: 4380);
        s.To(D((P.Glow, 0.5)), 700, at: 4380);
        s.To(D((P.Follow, 1)), 700, at: 4380);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>不播過場的展開：從迷你位置滑到角色卡</summary>
    public MascotScript QuickOpen(long start, MascotPose from, MascotMode mode)
    {
        var s = new MascotScript(start, from.With(D((P.Tint, 1), (P.Dot, 1), (P.Sc, 1))));
        AppendRest(s, mode, 300);
        s.To(D((P.X, Hero.Card.X), (P.Y, Hero.Card.Y), (P.R, Hero.Card.Radius)), 620, MascotEase.ExpoOut);
        s.To(D((P.Glow, 0.5)), 500);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>從任何姿勢（含過場途中）接到卡片上目前模式的姿勢：同快速展開，但服務色、額度等級、大小也是漸變</summary>
    public MascotScript Settle(long start, MascotPose from, MascotMode mode)
    {
        var s = new MascotScript(start, from);
        AppendRest(s, mode, 300);
        s.To(D((P.X, Hero.Card.X), (P.Y, Hero.Card.Y), (P.R, Hero.Card.Radius)), 620, MascotEase.ExpoOut);
        s.To(D((P.Tint, 1), (P.Dot, 1), (P.Sc, 1)), 300);
        s.To(D((P.Glow, 0.5)), 500);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>收合時的姿勢依模式：睡覺時閉眼低頭（頭只低一半）、需要你舉手、工作中低頭看鍵盤且不看游標</summary>
    public MascotPose CollapsedPoseFor(MascotMode mode) => mode switch
    {
        MascotMode.Sleep => CollapsedPose.With(D((P.Pitch, Config.Poses.Sleep.Pitch * 0.45), (P.Dash, 1), (P.Follow, 0))),
        MascotMode.Raise => CollapsedPose.With(RaiseHands),
        MascotMode.Work => CollapsedPose.With(D((P.Pitch, Config.Poses.Work.Pitch), (P.Follow, 0))),
        // 背景執行中：平常的迷你角色、臉朝正前方不看游標；思考泡泡與呼吸由 App 的收合循環另外畫
        MascotMode.Think => CollapsedPose.With(D((P.Follow, 0))),
        _ => CollapsedPose,
    };

    /// <summary>舉手的姿勢（展開與收合共用；位置、大小另外決定）</summary>
    private Dictionary<P, double> RaiseHands
    {
        get
        {
            var r = Config.Poses.Raise;
            return D((P.Hands, 1), (P.Wave, 0), (P.Pitch, r.Pitch), (P.Roll, r.Roll), (P.Yaw, 0),
                (P.Lx, r.Left[0]), (P.Ly, r.Left[1]), (P.Lz, r.Left[2]), (P.Rx, r.Right[0]), (P.Ry, r.Right[1]), (P.Rz, r.Right[2]));
        }
    }

    /// <summary>收合時滑回迷你位置的屬性</summary>
    private static readonly P[] CloseProps =
        [P.X, P.Y, P.R, P.Sc, P.Sway, P.Glow, P.Tint, P.Dot, P.Sx, P.Sy, P.Jump, P.Orbit, P.Shiver, P.Blush, P.Type, P.Kb, P.Breathe];

    /// <summary>收著時換姿勢會動到的屬性</summary>
    private static readonly P[] CollapsedProps = [P.Pitch, P.Dash, P.Yaw, P.Roll, P.Hands, P.Wave, P.Lx, P.Ly, P.Lz, P.Rx, P.Ry, P.Rz];

    private static Dictionary<P, double> Pick(IEnumerable<P> props, MascotPose pose) => props.Distinct().ToDictionary(p => p, p => pose[p]);

    /// <summary>收著時換模式（睡著、醒來、舉手、放下）：迷你角色換姿勢一次（.4 秒），之後靜止</summary>
    public MascotScript CollapsedRest(long start, MascotPose from, MascotMode mode)
    {
        var s = new MascotScript(start, from);
        var target = CollapsedPoseFor(mode);
        s.To(Pick(CollapsedProps, target), 400, MascotEase.InOut);
        s.To(D((P.Follow, target[P.Follow])), 300);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>收著時 AI 完成：迷你角色舉起右手揮一下，再回到目前模式的姿勢；收合途中完成時照樣滑回迷你位置</summary>
    public MascotScript CollapsedCheer(long start, MascotPose from, MascotMode mode)
    {
        var s = new MascotScript(start, from);
        var mini = CollapsedPoseFor(mode);
        s.To(Pick(CloseProps, mini), Config.Panel.CloseGlideMs, MascotEase.InOut);
        var wave = Config.Poses.CheerWaveMs;
        s.To(D((P.Hands, 1), (P.Pitch, 0), (P.Dash, 0)), 200, MascotEase.Back);
        s.To(D((P.Wave, 1)), 200);
        s.SetEyes(MascotEyes.Happy, at: 150);
        s.SetEyes(MascotEyes.Pill, at: 150 + wave);
        s.To(D((P.Wave, 0)), 200, at: 200 + wave);
        s.To(Pick(CollapsedProps, mini), 320, MascotEase.InOut, at: 300 + wave);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>收合：角色縮回迷你位置（同一顆球連續移動）；睡覺中的收成閉眼的迷你角色</summary>
    public MascotScript Close(long start, MascotPose from, MascotMode mode = MascotMode.None)
    {
        var s = new MascotScript(start, from);
        var mini = CollapsedPoseFor(mode);
        IEnumerable<P> props = CloseProps.Concat([P.Hands, P.Wave, P.Dash, P.Pitch, P.Yaw, P.Roll]);
        if (mode == MascotMode.Raise) props = props.Concat(CollapsedProps);
        s.To(Pick(props, mini), Config.Panel.CloseGlideMs, MascotEase.InOut);
        s.To(D((P.Follow, mini[P.Follow])), 200);
        s.FinalizeOrder();
        return s;
    }

    // MARK: 模式姿勢

    /// <summary>動畫播完、回到目前模式的姿勢</summary>
    public MascotScript Rest(long start, MascotPose from, MascotMode mode)
    {
        var s = new MascotScript(start, from);
        AppendRest(s, mode, null);
        s.FinalizeOrder();
        return s;
    }

    private void AppendRest(MascotScript s, MascotMode mode, int? duration)
    {
        s.SetEyes(MascotEyes.Pill);
        switch (mode)
        {
            case MascotMode.Work:
                var w = Config.Poses.Work;
                s.To(D((P.Sx, 1), (P.Sy, 1), (P.Jump, 0), (P.Orbit, 0), (P.Shiver, 0), (P.Blush, 0), (P.Yaw, 0), (P.Pitch, w.Pitch),
                        (P.Roll, 0), (P.Dash, 0), (P.Hands, 1), (P.Wave, 0), (P.Sway, 0), (P.Breathe, 0), (P.Type, 1), (P.Kb, 1),
                        (P.Follow, w.Follow), (P.Lx, w.Left[0]), (P.Ly, w.Left[1]), (P.Lz, w.Left[2]), (P.Rx, w.Right[0]),
                        (P.Ry, w.Right[1]), (P.Rz, w.Right[2])),
                    duration ?? Config.Poses.WorkMs, MascotEase.InOut);
                break;
            case MascotMode.Sleep:
                var sleep = Config.Poses.Sleep;
                s.To(D((P.Pitch, sleep.Pitch), (P.Yaw, 0), (P.Roll, 0), (P.Dash, 1), (P.Hands, 0), (P.Wave, 0), (P.Type, 0), (P.Kb, 0),
                    (P.Breathe, 1), (P.Glow, sleep.Glow), (P.Follow, 0)), duration ?? sleep.EnterMs, MascotEase.InOut);
                break;
            case MascotMode.Raise:
                s.To(Merge(D((P.Sx, 1), (P.Sy, 1), (P.Jump, 0), (P.Orbit, 0), (P.Shiver, 0), (P.Blush, 0), (P.Dash, 0), (P.Sway, 0),
                        (P.Breathe, 0), (P.Type, 0), (P.Kb, 0), (P.Follow, 1)), RaiseHands),
                    duration ?? Config.Poses.RaiseMs, MascotEase.BackSoft);
                break;
            default:
                s.To(Merge(D((P.Sx, 1), (P.Sy, 1), (P.Jump, 0), (P.Orbit, 0), (P.Shiver, 0), (P.Blush, 0), (P.Yaw, 0), (P.Pitch, 0),
                        (P.Roll, 0), (P.Dash, 0), (P.Hands, 0), (P.Wave, 0), (P.Sway, 0), (P.Breathe, 0), (P.Type, 0), (P.Kb, 0),
                        (P.Follow, 1)), RestHands),
                    duration ?? Config.Poses.RestMs, MascotEase.InOut);
                break;
        }
    }

    // MARK: 收著時的提醒

    /// <summary>收合時的提醒：迷你角色跳一下（瀏海鼓一下由 MascotBump 計算）</summary>
    public MascotScript CollapsedAlert(long start, MascotPose from, int level)
    {
        var s = new MascotScript(start, from);
        s.Effect(new MascotEffectKind.Ring(level), 900);
        Hop(s, Config.Expressions.CollapsedAlert.Hop);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>跳一下的壓扁、起跳、落地、回彈（demo 的 hopSeq）</summary>
    internal static void Hop(MascotScript s, double height, int offset = 0)
    {
        s.To(D((P.Sx, 1.16), (P.Sy, 0.84)), 110, MascotEase.Out, at: offset);
        s.To(D((P.Jump, -height), (P.Sx, 0.9), (P.Sy, 1.12)), 230, MascotEase.Out, at: offset + 110);
        s.To(D((P.Jump, 0), (P.Sx, 0.96), (P.Sy, 1.05)), 190, MascotEase.InCubic, at: offset + 340);
        s.To(D((P.Sx, 1.14), (P.Sy, 0.86)), 80, MascotEase.Out, at: offset + 530);
        s.To(D((P.Sx, 0.96), (P.Sy, 1.04)), 120, MascotEase.InOut, at: offset + 610);
        s.To(D((P.Sx, 1), (P.Sy, 1)), 150, MascotEase.InOut, at: offset + 730);
    }

    // MARK: 表情與動畫（MASCOT-SPEC 第 5 節；MascotExpressions.swift）

    public MascotScript Animation(MascotAnimation animation, long start, MascotPose from, int level)
    {
        var s = new MascotScript(start, from);
        Neutral(s, animation == MascotAnimation.Squeeze ? 100 : Config.Poses.NeutralMs);
        switch (animation)
        {
            case MascotAnimation.Hop:
                s.SetEyes(MascotEyes.Happy);
                s.To(D((P.Follow, 0), (P.Yaw, 0), (P.Pitch, 0.05)), 150);
                Hop(s, 0.8);
                break;
            case MascotAnimation.Wave:
                s.To(Merge(D((P.Hands, 1)), RestHands), 380, MascotEase.Back);
                s.To(D((P.Wave, 1)), 220);
                s.To(D((P.Sway, 0.6), (P.Pitch, 0.15), (P.Yaw, -0.2), (P.Follow, 0)), 300, MascotEase.InOut);
                s.SetEyes(MascotEyes.Happy, at: 350);
                s.To(D((P.Wave, 0), (P.Sway, 0)), 220, at: 1500);
                s.To(D((P.Hands, 0)), 280, MascotEase.InCubic, at: 1500);
                s.SetEyes(MascotEyes.Pill, at: 1500);
                break;
            case MascotAnimation.Nod:
                s.To(D((P.Follow, 0), (P.Yaw, 0), (P.Pitch, -0.35)), 180, MascotEase.InOut);
                s.SetEyes(MascotEyes.Happy, at: 150);
                s.To(D((P.Pitch, 0.1)), 160, MascotEase.InOut, at: 180);
                s.To(D((P.Pitch, -0.25)), 160, MascotEase.InOut, at: 340);
                s.To(D((P.Pitch, 0)), 200, MascotEase.InOut, at: 500);
                s.SetEyes(MascotEyes.Pill, at: 620);
                s.To(D((P.Follow, 1)), 180, at: 620);
                break;
            case MascotAnimation.Tilt:
                s.To(D((P.Follow, 0), (P.Roll, 0.28), (P.Yaw, 0.18), (P.Pitch, 0.06), (P.Jump, -0.05)), 260, MascotEase.Back);
                s.To(D((P.Roll, 0), (P.Yaw, 0), (P.Pitch, 0), (P.Jump, 0)), 260, MascotEase.InOut, at: 720);
                s.To(D((P.Follow, 1)), 200, at: 800);
                break;
            case MascotAnimation.Giggle:
                s.SetEyes(MascotEyes.Happy);
                s.To(D((P.Follow, 0), (P.Yaw, 0), (P.Pitch, 0.08), (P.Sway, 0.45)), 200);
                s.To(D((P.Jump, -0.15), (P.Sx, 0.96), (P.Sy, 1.04)), 120, MascotEase.Out, at: 100);
                s.To(D((P.Jump, 0), (P.Sx, 1.04), (P.Sy, 0.96)), 120, MascotEase.InCubic, at: 220);
                s.To(D((P.Jump, -0.12), (P.Sx, 0.97), (P.Sy, 1.03)), 120, MascotEase.Out, at: 340);
                s.To(D((P.Jump, 0), (P.Sx, 1), (P.Sy, 1)), 140, MascotEase.InCubic, at: 460);
                s.To(D((P.Sway, 0), (P.Pitch, 0)), 240, MascotEase.InOut, at: 720);
                s.SetEyes(MascotEyes.Pill, at: 880);
                s.To(D((P.Follow, 1)), 120, at: 880);
                break;
            case MascotAnimation.Look:
                s.To(D((P.Follow, 0), (P.Yaw, -0.45), (P.Roll, -0.04), (P.Pitch, 0.04)), 260, MascotEase.InOut);
                s.To(D((P.Yaw, 0.45), (P.Roll, 0.04)), 320, MascotEase.InOut, at: 450);
                s.To(D((P.Yaw, 0), (P.Roll, 0), (P.Pitch, 0)), 260, MascotEase.InOut, at: 950);
                s.To(D((P.Follow, 1)), 120, at: 1180);
                break;
            case MascotAnimation.Pinch:
                s.SetEyes(MascotEyes.Xx);
                s.To(Squeezed, 180);
                s.SetEyes(MascotEyes.Happy, at: 300);
                s.To(D((P.Sx, 0.8), (P.Sy, 1.22)), 110, at: 300);
                s.To(D((P.Sx, 1.1), (P.Sy, 0.9)), 120, MascotEase.InOut, at: 410);
                s.To(D((P.Sx, 0.96), (P.Sy, 1.04)), 120, MascotEase.InOut, at: 530);
                s.To(D((P.Sx, 1), (P.Sy, 1)), 170, MascotEase.InOut, at: 650);
                s.To(D((P.Hands, 0)), 250, MascotEase.InCubic, at: 550);
                s.SetEyes(MascotEyes.Pill, at: 950);
                s.To(D((P.Follow, 1)), 150, at: 950);
                break;
            case MascotAnimation.FaceHappy or MascotAnimation.FaceWorried or MascotAnimation.FaceSad or MascotAnimation.FaceSick
                or MascotAnimation.FaceSurprised or MascotAnimation.FaceOut or MascotAnimation.FaceStale:
                // 選單的「表情」：正面看著你一下，眼睛與眉毛照這個動畫的表情（MascotMoods.Face）
                s.To(D((P.Follow, 0), (P.Yaw, 0), (P.Pitch, 0.04)), 220, MascotEase.InOut);
                s.To(D((P.Jump, -0.08)), 140, MascotEase.Out, at: 60);
                s.To(D((P.Jump, 0)), 160, MascotEase.InCubic, at: 200);
                s.To(D((P.Follow, 1), (P.Pitch, 0)), 220, MascotEase.InOut, at: 1900);
                break;
            case MascotAnimation.Dizzy:
                s.SetEyes(MascotEyes.Spiral);
                s.To(D((P.Follow, 0), (P.Orbit, 1), (P.Sway, 1.2), (P.Hands, 1), (P.Lx, -1.1), (P.Ly, 0.9), (P.Lz, 0.3), (P.Rx, 1.1),
                    (P.Ry, 0.9), (P.Rz, 0.3)), 320);
                s.To(D((P.Orbit, 0), (P.Sway, 0)), 300, at: 2300);
                s.To(D((P.Hands, 0)), 300, MascotEase.InCubic, at: 2300);
                s.SetEyes(MascotEyes.Pill, at: 2500);
                s.To(D((P.Yaw, -0.3)), 90, MascotEase.InOut, at: 2500);
                s.To(D((P.Yaw, 0.3)), 110, MascotEase.InOut, at: 2600);
                s.To(D((P.Yaw, 0)), 120, MascotEase.InOut, at: 2720);
                break;
            case MascotAnimation.Shy:
                s.To(D((P.Follow, 0), (P.Yaw, -0.42), (P.Pitch, -0.28), (P.Roll, -0.08), (P.Blush, 1)), 360, MascotEase.InOut);
                s.To(D((P.Hands, 1), (P.Lx, -0.74), (P.Ly, 0.3), (P.Lz, 0.9), (P.Rx, -0.12), (P.Ry, 0.3), (P.Rz, 0.9)), 420);
                s.SetEyes(MascotEyes.Happy, at: 150);
                s.Effect(new MascotEffectKind.Heart(), 1300, at: 300);
                s.To(D((P.Rx, 0.42), (P.Ry, 0.62), (P.Rz, 0.8), (P.Yaw, -0.2), (P.Pitch, -0.1)), 260, MascotEase.InOut, at: 1050);
                s.SetEyes(MascotEyes.Pill, at: 1050);
                s.To(D((P.Rx, -0.12), (P.Ry, 0.3), (P.Rz, 0.9), (P.Yaw, -0.42), (P.Pitch, -0.28)), 240, MascotEase.InOut, at: 1450);
                s.SetEyes(MascotEyes.Happy, at: 1450);
                s.To(D((P.Blush, 0)), 300, at: 1900);
                break;
            case MascotAnimation.Scared:
                s.SetEyes(MascotEyes.Dot);
                s.To(D((P.Follow, 0), (P.Yaw, 0), (P.Pitch, 0.1), (P.Sx, 1.2), (P.Sy, 0.8)), 70);
                s.Effect(new MascotEffectKind.Bang(), 1200);
                s.To(D((P.Jump, -1.0), (P.Sx, 0.85), (P.Sy, 1.18)), 200, at: 70);
                s.To(D((P.Hands, 1), (P.Lx, -1.15), (P.Ly, -0.55), (P.Lz, 0.25), (P.Rx, 1.15), (P.Ry, -0.55), (P.Rz, 0.25)), 240,
                    MascotEase.Back, at: 70);
                s.To(D((P.Jump, 0), (P.Sx, 1), (P.Sy, 1)), 220, MascotEase.InCubic, at: 270);
                s.To(D((P.Sx, 1.1), (P.Sy, 0.9)), 70, at: 490);
                s.To(D((P.Sx, 1), (P.Sy, 1)), 140, MascotEase.InOut, at: 560);
                s.To(D((P.Shiver, 1)), 100, at: 560);
                s.To(D((P.Shiver, 0)), 200, at: 1250);
                break;
            case MascotAnimation.Wake:
                s.SetEyes(MascotEyes.Dot);
                s.To(D((P.Pitch, 0), (P.Dash, 0), (P.Breathe, 0), (P.Glow, 0.5)), 260);
                s.Effect(new MascotEffectKind.Bang(), 1000);
                Hop(s, 0.5);
                s.SetEyes(MascotEyes.Pill, at: 500);
                break;
            case MascotAnimation.Alert:
                // 眼睛照額度的表情（擔心的小圓點、用完的 ×；MascotDirector.Mood）
                s.SetEyes(MascotEyes.Pill);
                s.Effect(new MascotEffectKind.Ring(level), 900);
                s.To(D((P.Glow, 1)), 150);
                s.To(D((P.Glow, 0.5)), 500, at: 300);
                Hop(s, 0.6);
                break;
            case MascotAnimation.Squeeze:
                s.SetEyes(MascotEyes.Xx);
                s.To(Squeezed, 180);
                break;
        }
        s.FinalizeOrder();
        return s;
    }

    private static Dictionary<P, double> Squeezed =>
        D((P.Follow, 0), (P.Sx, 1.3), (P.Sy, 0.7), (P.Hands, 1), (P.Lx, -1.38), (P.Ly, 0.38), (P.Lz, 0.2), (P.Rx, 1.38), (P.Ry, 0.38),
            (P.Rz, 0.2), (P.Pitch, 0), (P.Yaw, 0));

    /// <summary>放開捏扁：像果凍回彈</summary>
    public MascotScript SqueezeRelease(long start, MascotPose from)
    {
        var s = new MascotScript(start, from, MascotEyes.Happy);
        s.To(D((P.Sx, 0.8), (P.Sy, 1.22)), 110);
        s.To(D((P.Sx, 1.1), (P.Sy, 0.9)), 120, MascotEase.InOut, at: 110);
        s.To(D((P.Sx, 0.96), (P.Sy, 1.04)), 120, MascotEase.InOut, at: 230);
        s.To(D((P.Sx, 1), (P.Sy, 1)), 170, MascotEase.InOut, at: 350);
        s.To(D((P.Hands, 0)), 250, MascotEase.InCubic, at: 250);
        s.FinalizeOrder();
        return s;
    }

    /// <summary>每個動畫開始前歸零（demo 的 neutral）。睡覺中播的也從這裡開始：抬起頭、睜開眼，播完再回到睡覺的姿勢</summary>
    private void Neutral(MascotScript s, int duration)
    {
        s.SetEyes(MascotEyes.Pill);
        s.To(D((P.Sx, 1), (P.Sy, 1), (P.Jump, 0), (P.Orbit, 0), (P.Shiver, 0), (P.Blush, 0), (P.Wave, 0), (P.Sway, 0), (P.Roll, 0),
            (P.Dash, 0), (P.Breathe, 0), (P.Type, 0), (P.Kb, 0), (P.Hands, 0), (P.Pitch, 0), (P.Glow, 0.5)), duration, MascotEase.InOut);
    }
}
