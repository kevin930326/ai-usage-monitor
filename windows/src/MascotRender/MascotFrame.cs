using AIUsageMonitor.Core;

namespace AIUsageMonitor.Mascot;

// 角色某一刻要畫的全部內容（同 Mac 的 MascotDrawing.swift MascotFrame）。MascotDirector 依狀態機產生，
// 截圖工具也可以直接組出來（固定時間與種子）。

/// <summary>角色的服務色（MASCOT-SPEC 第 2 節的色票）</summary>
public enum MascotCharacter { Claude, Codex }

public static class MascotCharacters
{
    public static MascotTint Tint(this MascotCharacter character, MascotPalette palette) =>
        character == MascotCharacter.Claude ? palette.Claude : palette.Codex;

    public static string Provider(this MascotCharacter character) => character == MascotCharacter.Claude ? "claude" : "codex";
}

public sealed record MascotFrame
{
    public required long Time { get; init; }
    public required MascotPose Pose { get; init; }
    public MascotEyes Eyes { get; init; } = MascotEyes.Pill;
    /// <summary>眨眼（0…1，疊加在 dash 上）</summary>
    public double Blink { get; init; }
    /// <summary>看滑鼠的偏航、俯仰（已平滑）</summary>
    public double GazeYaw { get; init; }
    public double GazePitch { get; init; }
    /// <summary>提醒光環的顏色（0 正常 → 1 偏高 → 2 用完）</summary>
    public double StatusColor { get; init; }
    /// <summary>平常的表情（眼睛是膠囊、沒在閉眼時換成表情的眼睛與眉毛）</summary>
    public MascotMood Mood { get; init; } = MascotMood.Normal;
    public bool Sleeping { get; init; }
    /// <summary>收著時睡著：迷你角色旁的小 z</summary>
    public bool Dozing { get; init; }
    /// <summary>收著睡著時小 z 飄起的進度（0…1）；null 時 z 靜止</summary>
    public double? DozeRise { get; init; }
    /// <summary>收合時 AI 工作中的思考泡泡：三個小點中亮了幾顆（0…3）；null 時不畫</summary>
    public int? ThinkingDots { get; init; }
    public IReadOnlyList<MascotEffect> Effects { get; init; } = [];
    public MascotRipple? Ripple { get; init; }
    public MascotCharacter Character { get; init; } = MascotCharacter.Claude;
    /// <summary>角色外觀（ADR-0021）；null 是跟著服務色</summary>
    public MascotLook? Look { get; init; }
    /// <summary>特效的時間（毫秒）；null 時特效畫靜態的一格（收合閒置、動畫簡單或關閉）</summary>
    public long? EffectTime { get; init; }
}
