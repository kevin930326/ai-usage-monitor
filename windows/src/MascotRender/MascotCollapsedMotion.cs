using AIUsageMonitor.Core;

namespace AIUsageMonitor.Mascot;

// 收合時的動態（ADR-0021，同 Mac NotchView.swift 的 MascotEffectLoop.plan）：角色停在收合的位置，只有小範圍在動，
// 所以先畫好一輪、循環播放（App 每一格不用重新跑狀態機）。
// - AI 工作中：會動的特效照特效動；其他外觀是敲鍵盤（小手上下、身體輕晃、淺灰鍵盤的按鍵輪流亮）。所有外觀的右上方都有
//   思考泡泡（三個小點依序亮起）。每秒 12 格；收合工作中不看滑鼠
// - 睡著：慢慢的呼吸（約 4.4 秒一次）加一個飄起的小 z；特效停在那一格。每秒 4 格
public sealed record MascotCollapsedMotion(double Length, double Fps, Func<long, MascotFrame> Frame)
{
    /// <summary>敲鍵盤：手 sin(t/62)、身體晃 sin(t/310)，一輪 2π·310 毫秒剛好是敲 5 下</summary>
    public static readonly double TypingMs = 2 * Math.PI * 310;
    /// <summary>呼吸 sin(t/700)</summary>
    public static readonly double BreathMs = 2 * Math.PI * 700;

    /// <summary>一輪幾格</summary>
    public int Count => Math.Max(1, (int)Math.Round(Length / 1000 * Fps, MidpointRounding.AwayFromZero));

    /// <summary>第 k 格的時間（一輪內的毫秒）</summary>
    public long TimeOf(int k) => (long)Math.Round(k * Length / Count, MidpointRounding.AwayFromZero);

    /// <summary>角色停在 stoppedAt；frozenEffect 是睡著時特效停住的那一格（null 是靜態）。不是工作中或睡著時沒有動態（null）</summary>
    public static MascotCollapsedMotion? Plan(MascotDirector director, long stoppedAt, MascotCharacter character, MascotLook? look,
        long? frozenEffect = null)
    {
        var baseFrame = MascotFrames.From(director, stoppedAt, character, look, gaze: (0, 0));
        var basePose = baseFrame.Pose;
        switch (director.Mode)
        {
            case MascotMode.Work:
                if (look is not null && MascotLookPainter.LoopDuration(look, basePose[MascotProp.R] * basePose[MascotProp.Sc]) is { } effect)
                {
                    return new MascotCollapsedMotion(effect, 12,
                        t => baseFrame with { EffectTime = t, ThinkingDots = MascotThinking.Dots(t, effect) });
                }
                // 手放在身體前下方，前面一條淺灰鍵盤（同展開時敲鍵盤的位置）
                var w = director.Config.Poses.Work;
                var typing = basePose.With(new Dictionary<MascotProp, double>
                {
                    [MascotProp.Hands] = 1, [MascotProp.Type] = 1, [MascotProp.Kb] = 1, [MascotProp.Sway] = 0.5,
                    [MascotProp.Lx] = w.Left[0], [MascotProp.Ly] = w.Left[1], [MascotProp.Lz] = w.Left[2],
                    [MascotProp.Rx] = w.Right[0], [MascotProp.Ry] = w.Right[1], [MascotProp.Rz] = w.Right[2],
                });
                return new MascotCollapsedMotion(TypingMs, 12,
                    t => baseFrame with { Pose = typing, Time = t, EffectTime = null, ThinkingDots = MascotThinking.Dots(t, TypingMs) });
            case MascotMode.Sleep:
                var breathing = basePose.With(MascotProp.Breathe, 1);
                return new MascotCollapsedMotion(BreathMs, 4,
                    t => baseFrame with { Pose = breathing, Time = t, EffectTime = frozenEffect, DozeRise = t % BreathMs / BreathMs });
            default:
                return null;
        }
    }
}
