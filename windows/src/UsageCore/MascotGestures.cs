namespace AIUsageMonitor.Core;

// 角色視窗裡的滑鼠手勢（ADR-0016 第 2 節、demo 的 mousemove）：繞著角色畫兩圈 → 轉暈、快速左右甩動 → 嚇到、
// 停在角色身上 → 害羞。只吃角色自己視窗裡的移動（不裝全域鉤子）；時間與座標由呼叫端給，純邏輯。
// 和 Mac 的 UsageKit/MascotGestures.swift 是同一份規則（門檻換算成 60 Hz 一格，滑鼠事件頻率不同時手感相同）。

public sealed class MascotGestureDetector(MascotGesturesConfig gestures, int hoverShyMs)
{
    /// <summary>demo 的一個 mousemove（60 Hz）</summary>
    private const double FrameMs = 1000.0 / 60;

    private double? lastAngle;
    private long lastAngleTime;
    private double? lastX;
    private long? lastMoveTime;
    private double lastDx;
    private int reversals;
    private long reversalTime;
    private long? hoverStart;

    public MascotGestureDetector(MascotConfig config) : this(config.Gestures, config.Interaction.HoverShyMs) { }

    public MascotGesturesConfig Gestures { get; } = gestures;
    public int HoverShyMs { get; } = hoverShyMs;

    /// <summary>累積繞過的角度（弧度，會衰減）</summary>
    public double Turned { get; private set; }

    /// <summary>滑鼠移到 (x, y)（畫布座標）；center、radius 是角色此刻的位置與半徑。
    /// canDetect 為 false（收合、過場、播放中、按住、睡覺）時清掉累積，什麼都不觸發</summary>
    public MascotGesture? Move(double x, double y, long time, double centerX, double centerY, double radius, bool canDetect)
    {
        double dx = x - centerX, dy = y - centerY;
        var distance = Math.Sqrt(dx * dx + dy * dy);
        // 距離上一個事件幾格（60 Hz 一格；最多算 4 格，停很久再動不會一次衰減光）
        var frames = lastMoveTime is { } last ? Math.Min(Math.Max((time - last) / FrameMs, 0.25), 4) : 1;
        var moveX = lastX is { } lx ? x - lx : 0;
        lastX = x;
        lastMoveTime = time;
        if (!canDetect)
        {
            Reset(keepingX: true);
            return null;
        }

        // 繞圈：在半徑內，相鄰兩次取樣間隔夠短時累積角度變化
        if (distance < Gestures.CircleRadiusPx)
        {
            var angle = Math.Atan2(dy, dx);
            if (lastAngle is { } previous && time - lastAngleTime < Gestures.CircleSampleGapMs)
            {
                var delta = angle - previous;
                if (delta > Math.PI) delta -= 2 * Math.PI;
                if (delta < -Math.PI) delta += 2 * Math.PI;
                Turned += delta;
            }
            lastAngle = angle;
            lastAngleTime = time;
        }
        else
        {
            lastAngle = null;
        }
        Turned *= Math.Pow(Gestures.CircleDecayPerMove, frames);
        if (Math.Abs(Turned) > Gestures.CircleTurns * 2 * Math.PI)
        {
            Turned = 0;
            return MascotGesture.Circle;
        }

        // 甩動：夠快的水平移動換方向的次數；停太久就重算
        if (Math.Abs(moveX) / frames > Gestures.ShakeMinDxPx && distance < Gestures.ShakeRadiusPx)
        {
            if (lastDx != 0 && moveX > 0 != lastDx > 0)
            {
                reversals += 1;
                reversalTime = time;
            }
            lastDx = moveX;
        }
        if (time - reversalTime > Gestures.ShakeResetMs) reversals = 0;
        if (reversals >= Gestures.ShakeReversals)
        {
            reversals = 0;
            return MascotGesture.Shake;
        }

        // 停留：在角色身上超過 hover_shy_ms
        if (distance < radius)
        {
            if (hoverStart is { } start)
            {
                if (time - start > HoverShyMs)
                {
                    hoverStart = null;
                    return MascotGesture.Hover;
                }
            }
            else
            {
                hoverStart = time;
            }
        }
        else
        {
            hoverStart = null;
        }
        return null;
    }

    /// <summary>停在角色上時，何時該觸發害羞（滑鼠完全不動就沒有移動事件，呼叫端在這個時間排一次 CheckHover）</summary>
    public long? HoverDeadline => hoverStart + HoverShyMs + 1;

    /// <summary>到了停留的時間：滑鼠一直停在角色上就觸發害羞</summary>
    public MascotGesture? CheckHover(long time, bool canDetect)
    {
        if (hoverStart is not { } start) return null;
        if (!canDetect)
        {
            hoverStart = null;
            return null;
        }
        if (time - start <= HoverShyMs) return null;
        hoverStart = null;
        return MascotGesture.Hover;
    }

    /// <summary>滑鼠離開視窗：全部重來</summary>
    public void Reset() => Reset(keepingX: false);

    private void Reset(bool keepingX)
    {
        Turned = 0;
        lastAngle = null;
        reversals = 0;
        hoverStart = null;
        if (keepingX) return;
        lastX = null;
        lastDx = 0;
        lastMoveTime = null;
    }

    /// <summary>點擊是否落在角色上（半徑的 tap_hit_radius 倍）</summary>
    public bool Hits(double x, double y, double centerX, double centerY, double radius) =>
        Math.Sqrt((x - centerX) * (x - centerX) + (y - centerY) * (y - centerY)) < radius * Gestures.TapHitRadius;
}
