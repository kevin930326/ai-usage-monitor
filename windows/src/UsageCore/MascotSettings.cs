namespace AIUsageMonitor.Core;

/// <summary>懸浮圖示的樣式：角色（預設）、C2 雙圓環、角色加百分比（MASCOT-SPEC 第 9 節）</summary>
public enum RingStyle { Mascot, Ring, MascotPercent }

/// <summary>展開時的過場：每次、只有第一次（預設）、關閉</summary>
public enum MascotIntroChoice { Every, FirstOnly, Off }

/// <summary>
/// 動畫程度（同 Mac 的 MascotMotionLevel）：完整；簡單＝身體不動，只有眼睛眨與看滑鼠，不播過場、反應、光環、粒子，不偵測手勢；
/// 關閉＝只換表情。Windows「動畫效果」關閉時完整改成簡單。
/// </summary>
public enum MascotMotionLevel { Full, Simple, Off }

public static class MascotMotion
{
    public static MascotMotionLevel Effective(MascotMotionLevel level, bool animationsEnabled) =>
        !animationsEnabled && level == MascotMotionLevel.Full ? MascotMotionLevel.Simple : level;

    public static bool PlaysIntro(this MascotMotionLevel level) => level == MascotMotionLevel.Full;
    public static bool DrawsParticles(this MascotMotionLevel level) => level == MascotMotionLevel.Full;
    public static bool DetectsGestures(this MascotMotionLevel level) => level == MascotMotionLevel.Full;
    /// <summary>身體會動：點擊、手勢、提醒的反應，工作與睡覺的動作</summary>
    public static bool AnimatesBody(this MascotMotionLevel level) => level == MascotMotionLevel.Full;
    /// <summary>眼睛會動：眨眼、看滑鼠</summary>
    public static bool MovesEyes(this MascotMotionLevel level) => level != MascotMotionLevel.Off;
    /// <summary>外觀的特效會動；簡單、關閉時是靜態的一格</summary>
    public static bool AnimatesEffects(this MascotMotionLevel level) => level == MascotMotionLevel.Full;

    /// <summary>這次展開要不要播過場（只有第一次：這次執行還沒播過才播）</summary>
    public static bool ShouldPlayIntro(MascotIntroChoice choice, MascotMotionLevel motion, bool playedBefore) =>
        motion.PlaysIntro() && choice switch
        {
            MascotIntroChoice.Every => true,
            MascotIntroChoice.FirstOnly => !playedBefore,
            _ => false,
        };
}
