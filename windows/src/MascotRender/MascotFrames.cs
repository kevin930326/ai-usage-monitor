using AIUsageMonitor.Core;

namespace AIUsageMonitor.Mascot;

public static class MascotFrames
{
    /// <summary>從狀態機組出某一刻的畫面（同 Mac NotchCanvas.frame(at:)）。still：動畫「關閉」時眼睛不動（不眨眼、不看滑鼠）；
    /// gaze 有值時用它（截圖固定視線）</summary>
    public static MascotFrame From(MascotDirector director, long time, MascotCharacter character, MascotLook? look,
        long? effectTime = null, bool still = false, (double Yaw, double Pitch)? gaze = null, bool staticRemote = false)
    {
        var g = gaze ?? (still ? (0, 0) : director.Gaze(time));
        // 只有其他電腦在工作而想：泡泡亮兩顆＋旁邊的小電腦（ADR-0019「角色合併所有電腦」，同 Mac NotchView 的 frame(at:)）
        // staticRemote：動畫「簡單」「關閉」時狀態機不進 think，照合併後的狀態靜態顯示（Fable G-11）
        var remote = director.Machine.ThinksRemotely || staticRemote;
        return new MascotFrame
        {
            Time = time,
            Pose = director.Pose(time),
            Eyes = director.Eyes(time),
            Blink = still ? 0 : director.Blink(time),
            GazeYaw = g.Yaw,
            GazePitch = g.Pitch,
            StatusColor = director.StatusColor(time),
            Mood = director.MoodAt(time),
            Sleeping = director.ShowsSleep,
            Dozing = director.ShowsDoze,
            Effects = director.Effects.ToList(),
            Ripple = director.Ripple,
            Character = character,
            Look = look,
            EffectTime = effectTime,
            ThinkingDots = remote ? 2 : null,
            RemoteBadge = remote,
            RemoteBadgeAbove = director.Machine.IsOpen,
        };
    }
}
