using System.Globalization;
using System.Text.Json;

namespace AIUsageMonitor.Core;

// shared/mascot-anim.json 的完整內容（ADR-0016 第 3 節）。和 Mac 的 UsageKit/MascotConfig.swift 讀同一份檔案、
// 同樣的欄位；狀態機的部分另外解成 MascotTiming（鍵名不同的寫法，兩邊的 golden 共用）。
// 屬性名稱以 snake_case 對應 JSON 的鍵（JsonNamingPolicy.SnakeCaseLower）；required 的欄位缺少時解碼失敗，同 Swift。

/// <summary>角色與瀏海動畫的共用參數</summary>
public sealed record MascotConfig
{
    public required MascotTiming Timing { get; init; }
    public required MascotPanelConfig Panel { get; init; }
    public required MascotHeroConfig Hero { get; init; }
    public required MascotPalette Palette { get; init; }
    public required MascotPosesConfig Poses { get; init; }
    public required MascotIntroConfig Intro { get; init; }
    public required MascotRippleConfig Ripple { get; init; }
    public required MascotExpressionsConfig Expressions { get; init; }
    public required MascotGesturesConfig Gestures { get; init; }
    /// <summary>machine 裡狀態機以外的互動參數（停留多久害羞、單擊時隨機挑的短反應）</summary>
    public required MascotInteractionConfig Interaction { get; init; }

    internal static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    private sealed record File
    {
        public required MascotPanelConfig Panel { get; init; }
        public required MascotHeroConfig Hero { get; init; }
        public required MascotPalette Palette { get; init; }
        public required MascotPosesConfig Poses { get; init; }
        public required MascotIntroConfig Intro { get; init; }
        public required MascotRippleConfig Ripple { get; init; }
        public required MascotExpressionsConfig Expressions { get; init; }
        public required MascotGesturesConfig Gestures { get; init; }
        public required MascotInteractionConfig Machine { get; init; }
    }

    public static MascotConfig Decode(string json)
    {
        var file = JsonSerializer.Deserialize<File>(json, Options) ?? throw new JsonException("mascot-anim.json 是空的");
        return new MascotConfig
        {
            Timing = MascotTiming.FromConfig(json), Panel = file.Panel, Hero = file.Hero, Palette = file.Palette,
            Poses = file.Poses, Intro = file.Intro, Ripple = file.Ripple, Expressions = file.Expressions,
            Gestures = file.Gestures, Interaction = file.Machine,
        };
    }

    /// <summary>「#RRGGBB」→ [r, g, b]（0～255）；格式不對時是黑色（設定檔由測試檢查），同 Swift 的 MascotConfig.rgb</summary>
    public static double[] Rgb(string hex)
    {
        var digits = hex.StartsWith('#') ? hex[1..] : hex;
        if (digits.Length != 6 || !uint.TryParse(digits, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var value))
            return [0, 0, 0];
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];
    }
}

public sealed record MascotSize
{
    public required double Width { get; init; }
    public required double Height { get; init; }
    public required double Corner { get; init; }
}

public sealed record MascotSpringConfig
{
    public required double Stiffness { get; init; }
    public required double DampingRatio { get; init; }
}

public sealed record MascotPoint
{
    public required double X { get; init; }
    public required double Y { get; init; }
    public required double Radius { get; init; }
}

public sealed record MascotPanelConfig
{
    public required MascotSize Collapsed { get; init; }
    public required MascotSize Expanded { get; init; }
    public required double CornerOvershootMax { get; init; }
    public required MascotSpringConfig OpenSpring { get; init; }
    public required MascotSpringConfig CloseSpring { get; init; }
    public required int CloseDelayMs { get; init; }
    public required int ContentFadeOutMs { get; init; }
    public required int ContentFadeInMs { get; init; }
    public required double ContentRisePx { get; init; }
    public required int ContentRiseMs { get; init; }
    public required double MiniFadeFactor { get; init; }
    public required double StripHeight { get; init; }
    public required double StripTop { get; init; }
    public required PaddingConfig ContentPadding { get; init; }
    public required double CharacterCardWidth { get; init; }
    public required double CardCorner { get; init; }
    public required BumpConfig AlertBump { get; init; }
    public required int CloseGlideMs { get; init; }

    public sealed record PaddingConfig
    {
        public required double Top { get; init; }
        public required double Side { get; init; }
        public required double Bottom { get; init; }
    }

    public sealed record BumpConfig
    {
        public required double Width { get; init; }
        public required double Height { get; init; }
        public required int RiseMs { get; init; }
        public required int HoldMs { get; init; }
        public required int FallMs { get; init; }
    }
}

public sealed record MascotHeroConfig
{
    public required MascotPoint Mini { get; init; }
    public required MascotPoint Card { get; init; }
    public required IntroPlace Intro { get; init; }
    public required HighlightConfig BodyHighlight { get; init; }
    public required EyeConfig Eye { get; init; }
    public required HandConfig Hand { get; init; }
    public required HandRestConfig HandRest { get; init; }
    public required WaveConfig Wave { get; init; }
    public required GlowConfig Glow { get; init; }
    /// <summary>擔心、難過、生病時的眉毛</summary>
    public required BrowConfig Brow { get; init; }
    public required FollowConfig Follow { get; init; }
    public required BlinkConfig Blink { get; init; }
    /// <summary>工作中的鍵盤（展開與收合共用）</summary>
    public required KeyboardConfig Keyboard { get; init; }

    public sealed record IntroPlace
    {
        public required double X { get; init; }
        public required double Y { get; init; }
        public required double Radius { get; init; }
        public required double StartDrop { get; init; }
    }

    public sealed record HighlightConfig
    {
        public required double X { get; init; }
        public required double Y { get; init; }
        public required double Radius { get; init; }
    }

    public sealed record EyeConfig
    {
        public required double Width { get; init; }
        public required double Height { get; init; }
        public required double Yaw { get; init; }
        public required double Pitch { get; init; }
    }

    public sealed record HandConfig
    {
        public required double Radius { get; init; }
        public required double DepthScale { get; init; }
        public required double PopFrom { get; init; }
    }

    public sealed record HandRestConfig
    {
        public required double[] Left { get; init; }
        public required double[] Right { get; init; }
    }

    public sealed record WaveConfig
    {
        public required double[] Pivot { get; init; }
        public required double Radius { get; init; }
        public required double Angle { get; init; }
        public required double Swing { get; init; }
        public required double PeriodMs { get; init; }
    }

    public sealed record GlowConfig
    {
        public required double Inner { get; init; }
        public required double Outer { get; init; }
        public required double Alpha { get; init; }
    }

    public sealed record BrowConfig
    {
        public required double Yaw { get; init; }
        public required double Pitch { get; init; }
        public required double Width { get; init; }
        public required double Thickness { get; init; }
        public required double WorriedTilt { get; init; }
        public required double SadTilt { get; init; }
    }

    public sealed record FollowConfig
    {
        public required double YawMax { get; init; }
        public required double PitchMax { get; init; }
        public required double SmoothingPerFrame { get; init; }
        public required double YawSpanPx { get; init; }
        public required double PitchSpanPx { get; init; }
    }

    public sealed record BlinkConfig
    {
        public required int MinGapMs { get; init; }
        public required int MaxGapMs { get; init; }
        public required int CloseMs { get; init; }
        public required int HoldMs { get; init; }
        public required int OpenMs { get; init; }
    }

    public sealed record KeyboardConfig
    {
        public required double Y { get; init; }
        public required double Width { get; init; }
        public required double Height { get; init; }
        /// <summary>#RRGGBB</summary>
        public required string Color { get; init; }
        public required ShineConfig Shine { get; init; }
        public required KeysConfig Keys { get; init; }

        public sealed record ShineConfig
        {
            public required double X { get; init; }
            public required double Y { get; init; }
            public required double Width { get; init; }
            public required double Height { get; init; }
            public required double Alpha { get; init; }
        }

        public sealed record KeysConfig
        {
            public required int Count { get; init; }
            public required double X { get; init; }
            public required double Step { get; init; }
            public required double Y { get; init; }
            public required double Width { get; init; }
            public required double Height { get; init; }
            public required string Color { get; init; }
            public required double Phase { get; init; }
            public required double OnAbove { get; init; }
        }
    }
}

/// <summary>三階顏色與光暈（0～255 的 sRGB）</summary>
public sealed record MascotTint
{
    public required double[] Light { get; init; }
    public required double[] Mid { get; init; }
    public required double[] Shade { get; init; }
    public required double[] Glow { get; init; }
}

public sealed record MascotPalette
{
    public required MascotTint White { get; init; }
    public required MascotTint Claude { get; init; }
    public required MascotTint Codex { get; init; }
    public required StatusColors Status { get; init; }

    public sealed record StatusColors
    {
        public required double[] Normal { get; init; }
        public required double[] High { get; init; }
        public required double[] Out { get; init; }
    }
}

public sealed record MascotPosesConfig
{
    public required WorkPose Work { get; init; }
    public required SleepPose Sleep { get; init; }
    public required int RestMs { get; init; }
    public required int NeutralMs { get; init; }
    public required int WorkMs { get; init; }
    /// <summary>需要你：右手舉高（收合的迷你角色也一樣）</summary>
    public required RaisePose Raise { get; init; }
    public required int RaiseMs { get; init; }
    /// <summary>收著時完成：迷你角色揮手多久</summary>
    public required int CheerWaveMs { get; init; }

    public sealed record WorkPose
    {
        public required double Pitch { get; init; }
        public required double Follow { get; init; }
        public required double[] Left { get; init; }
        public required double[] Right { get; init; }
    }

    public sealed record SleepPose
    {
        public required double Pitch { get; init; }
        public required double Glow { get; init; }
        public required int EnterMs { get; init; }
    }

    public sealed record RaisePose
    {
        public required double Pitch { get; init; }
        public required double Roll { get; init; }
        public required double[] Left { get; init; }
        public required double[] Right { get; init; }
    }
}

public sealed record MascotIntroConfig
{
    public required int TotalMs { get; init; }
    public required double StartPitch { get; init; }
    public required int[] RingsAt { get; init; }
    public required int ConfettiAt { get; init; }
    public required int ContentAt { get; init; }
}

public sealed record MascotRippleConfig
{
    public required int Particles { get; init; }
    public required int DurationMs { get; init; }
    public required double RadiusFrom { get; init; }
    public required double RadiusSpan { get; init; }
    public required double ThicknessPx { get; init; }
    public required double EdgeWobblePx { get; init; }
    public required double EdgeWobbleLobes { get; init; }
    public required double VerticalSquash { get; init; }
    public required double FadeIn { get; init; }
    public required double TintFraction { get; init; }
    public required double TwinkleMs { get; init; }
    public required double EdgeFadePx { get; init; }
    public required double EdgeInsetPx { get; init; }
    public required FlashConfig EdgeFlash { get; init; }
    public required ConfettiConfig Confetti { get; init; }

    public sealed record FlashConfig
    {
        public required int Rings { get; init; }
        public required int Ms { get; init; }
        public required double[] Alpha { get; init; }
        public required double HitInsetPx { get; init; }
    }

    public sealed record ConfettiConfig
    {
        public required int Count { get; init; }
        public required int Ms { get; init; }
        public required double SpeedMin { get; init; }
        public required double SpeedSpan { get; init; }
        public required double XStretch { get; init; }
        public required double YStretch { get; init; }
    }
}

public sealed record MascotExpressionsConfig
{
    public required CollapsedAlertConfig CollapsedAlert { get; init; }

    public sealed record CollapsedAlertConfig
    {
        public required int Ms { get; init; }
        public required double Hop { get; init; }
    }
}

public sealed record MascotGesturesConfig
{
    public required double CircleRadiusPx { get; init; }
    public required int CircleSampleGapMs { get; init; }
    public required double CircleDecayPerMove { get; init; }
    public required double CircleTurns { get; init; }
    public required double ShakeMinDxPx { get; init; }
    public required double ShakeRadiusPx { get; init; }
    public required int ShakeReversals { get; init; }
    public required int ShakeResetMs { get; init; }
    public required double TapHitRadius { get; init; }
}

public sealed record MascotInteractionConfig
{
    public required int HoverShyMs { get; init; }
    /// <summary>單擊時平均隨機挑的短反應</summary>
    public required string[] TapReactions { get; init; }
}
