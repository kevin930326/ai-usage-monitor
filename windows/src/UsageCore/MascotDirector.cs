namespace AIUsageMonitor.Core;

// 把狀態機的事件串接成畫面（ADR-0016 第 1 節）：每個事件換一段腳本，起點是上一段在那一刻的姿勢；任一時間點的畫面
// 都可以由 Pose(time) 等直接算出（純函式），App 只需要在有事件時呼叫對應的方法。和 Mac 的 UsageKit/MascotDirector.swift
// 是同一份規則，fixtures/mascot-director 的 golden 兩邊比對；改規則時兩邊一起改。

public sealed class MascotDirector
{
    private bool quickOpening;
    private double statusFrom;
    private double statusTo;
    private long statusStart;
    private (double Yaw, double Pitch) gazeFrom;
    private (double Yaw, double Pitch) gazeTarget;
    private long gazeStart;
    private readonly List<MascotEffect> effects = [];

    /// <summary>statusLevel：啟動時已知的額度狀態（不鼓一下、不播提醒）</summary>
    public MascotDirector(MascotConfig config, ulong seed = 0x5EED, long startTime = 0, int statusLevel = 0)
    {
        Config = config;
        Scripts = new MascotScripts(config);
        Seed = seed;
        Machine = new MascotMachine(config.Timing, startTime, statusLevel);
        statusFrom = statusLevel;
        statusTo = statusLevel;
        statusStart = startTime - 1000;
        Script = new MascotScript(startTime, Scripts.CollapsedPose);
    }

    public MascotConfig Config { get; }
    public MascotScripts Scripts { get; }
    /// <summary>粒子與眨眼的種子</summary>
    public ulong Seed { get; }
    public MascotMachine Machine { get; }
    public MascotScript Script { get; private set; }
    public IReadOnlyList<MascotEffect> Effects => effects;
    public MascotSpring Spring { get; private set; } = MascotSpring.Resting(0);
    public long? BumpStart { get; private set; }
    public MascotRipple? Ripple { get; private set; }
    /// <summary>內容（額度卡）開始浮現的時間；收著或過場中為 null</summary>
    public long? ContentShownAt { get; private set; }
    public long? ContentHiddenAt { get; private set; }
    public bool IsIntro { get; private set; }
    /// <summary>角色身體靜止（動畫程度「簡單」「關閉」）：不播反應、提醒、工作與睡覺的動作，只換表情（額度）</summary>
    public bool IsStill { get; private set; }
    /// <summary>畫面看到的模式（依事件更新；Machine.Mode 是處理到目前時間的結果）</summary>
    public MascotMode Mode { get; private set; } = MascotMode.None;
    /// <summary>平常的表情（額度、AI 狀態）；立即生效</summary>
    public MascotMood Mood { get; private set; } = MascotMood.Normal;

    // MARK: 事件（時間一律是毫秒、單調遞增）

    public void Open(long time, bool intro) => Apply(m => m.Open(time, intro));
    public void Close(long time) => Apply(m => m.Close(time));
    public void Advance(long time) => Apply(m => m.Advance(time));
    public void Request(MascotRequest request, long time) => Apply(m => m.Request(request, time));
    public void Gesture(MascotGesture gesture, long time) => Apply(m => m.Gesture(gesture, time));
    public void Click(long time, MascotRequest choice) => Apply(m => m.Click(time, choice));
    public void Press(long time) => Apply(m => m.Press(time));
    public void Release(long time) => Apply(m => m.Release(time));
    public void SetWorking(bool working, long time) => Apply(m => m.SetWorking(working, time));
    public void SetStatus(int level, long time, bool react = true) => Apply(m => m.SetStatus(level, time, react));
    /// <summary>滑鼠在視窗裡移動（只推進時間；不叫醒，睡覺由 AI 的狀態決定）</summary>
    public void Move(long time) => Apply(m => m.Move(time));
    public void SetAgentIdle(bool idle, long time) => Apply(m => m.SetAgentIdle(idle, time));
    public void Silence(long time) => Apply(m => m.Silence(time));
    public void SetNeedsYou(bool needsYou, long time) => Apply(m => m.SetNeedsYou(needsYou, time));
    public void SetBackground(bool background, long time) => Apply(m => m.SetBackground(background, time));
    /// <summary>AI 完成一個回合（靜音、勿擾時 react 為 false，不揮手也不鼓）</summary>
    public void Cheer(long time, bool react = true) => Apply(m => m.Cheer(time, react));

    /// <summary>臉朝游標轉（dx、dy 是游標相對角色中心的距離，px）。目標和現在差不到 threshold（弧度）時不更新，
    /// 回傳 false，畫面不必重畫。snap 時直接轉到位（不平滑）</summary>
    public bool Look(long time, double dx, double dy, double threshold = 0, bool snap = false)
    {
        var f = Config.Hero.Follow;
        var target = (Math.Clamp(dx / f.YawSpanPx, -1, 1) * f.YawMax, Math.Clamp(-dy / f.PitchSpanPx, -1, 1) * f.PitchMax);
        if (!(Math.Abs(target.Item1 - gazeTarget.Yaw) > threshold || Math.Abs(target.Item2 - gazeTarget.Pitch) > threshold)) return false;
        gazeFrom = snap ? target : Gaze(time);
        gazeTarget = target;
        gazeStart = time;
        return true;
    }

    /// <summary>平常的表情（額度、AI 狀態）：立即換，不排隊</summary>
    public void SetMood(MascotMood mood) => Mood = mood;

    /// <summary>右鍵選單的「表情」：每個表情是各自的要求，照按鈕的規則排隊，播到才換表情</summary>
    public void RequestFace(MascotMood mood, long time)
    {
        if (mood.FaceRequest() is { } request) Request(request, time);
    }

    /// <summary>這一刻的表情：播「表情」時是那個動畫的表情，其他時候是平常的表情</summary>
    public MascotMood MoodAt(long time)
    {
        if (Machine.Playing is { } playing && time >= playing.Start && MascotMoods.Face(playing.Animation) is { } face) return face;
        return Mood;
    }

    /// <summary>下一個需要叫 Advance 的時間；沒有為 null</summary>
    public long? NextDeadline => Machine.NextDeadline;

    private void Apply(Action<MascotMachine> body)
    {
        body(Machine);
        foreach (var entry in Machine.Log.ToList()) Handle(entry);
        // 紀錄只用來接畫面；處理完就清掉，長時間執行也不會變長
        Machine.TrimLog();
    }

    private void Handle(MascotLogEntry entry)
    {
        var t = entry.Time;
        var pose = Script.Pose(t);
        var e = entry.Event;
        // 快速展開之後換了別的腳本，就不再是「滑到卡片途中」
        if (e is MascotEvent.Start or MascotEvent.Release or MascotEvent.Pose or MascotEvent.Bump or MascotEvent.Cheer or MascotEvent.IntroEnd)
            quickOpening = false;
        if (IsStill && e is MascotEvent.Start or MascotEvent.Release or MascotEvent.Pose or MascotEvent.Bump or MascotEvent.Cheer
                or MascotEvent.IntroEnd or MascotEvent.ModeChanged)
        {
            // 靜止時不換腳本；模式照記，姿勢維持平常的樣子
            if (e is MascotEvent.ModeChanged changed) Mode = changed.Mode;
            return;
        }
        switch (e)
        {
            case MascotEvent.Open open:
                Spring = Spring.Retarget(1, t, Config.Panel.OpenSpring.Stiffness, Config.Panel.OpenSpring.DampingRatio);
                ContentHiddenAt = null;
                if (open.Intro)
                {
                    IsIntro = true;
                    Use(Scripts.Intro(t));
                    Ripple = new MascotRipple(Config.Ripple, t, Config.Intro.RingsAt, Config.Intro.ConfettiAt, unchecked(Seed + (ulong)t));
                    ContentShownAt = t + Config.Intro.ContentAt;
                }
                else
                {
                    Use(Scripts.QuickOpen(t, pose, IsStill ? MascotMode.None : Mode));
                    quickOpening = true;
                    ContentShownAt = t + 220;
                }
                break;
            case MascotEvent.Close:
                quickOpening = false;
                // 內容先淡出，面板才收回
                Spring = Spring.Retarget(0, t + Config.Panel.ContentFadeOutMs, Config.Panel.CloseSpring.Stiffness,
                    Config.Panel.CloseSpring.DampingRatio);
                IsIntro = false;
                Ripple = null;
                effects.Clear();
                ContentShownAt = null;
                ContentHiddenAt = t;
                Use(Scripts.Close(t, pose, IsStill ? MascotMode.None : Mode));
                break;
            case MascotEvent.IntroEnd:
                IsIntro = false;
                if (Mode != MascotMode.None) Use(Scripts.Rest(t, pose, Mode));
                break;
            case MascotEvent.Start start:
                Use(Scripts.Animation(start.Animation, t, pose, Machine.StatusLevel));
                break;
            case MascotEvent.Release:
                Use(Scripts.SqueezeRelease(t, pose));
                break;
            case MascotEvent.Pose poseEvent:
                Use(Scripts.Rest(t, pose, poseEvent.Mode));
                break;
            case MascotEvent.ModeChanged changed:
                Mode = changed.Mode;
                // 收著：迷你角色換姿勢一次，之後靜止。收合（或提醒）還在播：從現在的姿勢重新收合
                if (!Machine.IsOpen)
                {
                    Use(Script.SettledAt > t
                        ? Scripts.Close(t, pose, IsStill ? MascotMode.None : changed.Mode)
                        : Scripts.CollapsedRest(t, pose, changed.Mode));
                    break;
                }
                // 動畫播放中：不打斷，播完時的 pose 事件會接到新模式的姿勢（ADR-0016 第 2 節的動畫鎖）
                if (IsIntro || Machine.Playing is not null) break;
                Use(quickOpening && Script.SettledAt > t
                    ? Scripts.QuickOpen(t, pose, changed.Mode)
                    : Scripts.Rest(t, pose, changed.Mode));
                break;
            case MascotEvent.Status status:
                statusFrom = StatusColor(t);
                statusTo = status.Level;
                statusStart = t;
                break;
            case MascotEvent.Bump:
                BumpStart = t;
                Use(Scripts.CollapsedAlert(t, pose, Machine.StatusLevel));
                break;
            case MascotEvent.Cheer:
                BumpStart = t;
                Use(Scripts.CollapsedCheer(t, pose, Mode));
                break;
        }
    }

    /// <summary>展開著睡著、而且身體會動時畫睡覺的 z</summary>
    public bool ShowsSleep => !IsStill && Mode == MascotMode.Sleep && Machine.IsOpen;
    /// <summary>收著時睡著：迷你角色旁邊一個小 z</summary>
    public bool ShowsDoze => !IsStill && Mode == MascotMode.Sleep && !Machine.IsOpen;

    /// <summary>改成靜止或恢復（動畫程度改變時）：改成靜止時，正在播的反應與特效立刻停，回到平常的姿勢</summary>
    public void SetStill(bool still, long time)
    {
        if (still == IsStill) return;
        IsStill = still;
        if (still)
        {
            effects.Clear();
            Ripple = null;
        }
        if (!Machine.IsOpen) return;
        var pose = Script.Pose(time);
        if (still && IsIntro)
        {
            // 過場途中改成靜止：直接收尾，角色滑到卡片、內容出現
            IsIntro = false;
            if (ContentShownAt is not { } shown || shown > time) ContentShownAt = time;
        }
        Use(Scripts.Settle(time, pose, still ? MascotMode.None : Machine.Mode));
        quickOpening = true;
    }

    private void Use(MascotScript next)
    {
        Script = next;
        effects.RemoveAll(e => e.Start + e.Duration <= next.Start);
        effects.AddRange(next.Effects);
    }

    // MARK: 畫面（純函式）

    public MascotPose Pose(long time) => Script.Pose(time);
    public MascotEyes Eyes(long time) => Script.Eyes(time);

    /// <summary>額度等級（0 正常 → 1 偏高 → 2 用完；提醒光環的顏色），換色 .4 秒</summary>
    public double StatusColor(long time) => statusFrom + (statusTo - statusFrom) * MascotEase.InOut.Apply((time - statusStart) / 400.0);

    /// <summary>看滑鼠：指數平滑（demo 每格乘 .12，換成與影格率無關的時間常數）</summary>
    public (double Yaw, double Pitch) Gaze(long time)
    {
        var perFrame = Config.Hero.Follow.SmoothingPerFrame;
        var tau = -1 / (60 * Math.Log(1 - perFrame));
        var k = Math.Exp(-Math.Max(time - gazeStart, 0) / 1000.0 / tau);
        return (gazeTarget.Yaw + (gazeFrom.Yaw - gazeTarget.Yaw) * k, gazeTarget.Pitch + (gazeFrom.Pitch - gazeTarget.Pitch) * k);
    }

    /// <summary>
    /// 眨眼：每 3.3～4.8 秒一次，只在平常狀態（沒有動畫、不是過場、沒睡覺、眼睛是膠囊、表情沒有換掉膠囊眼）。
    /// <paramref name="tab"/>：Windows 貼邊的標籤（收合也眨眼，睡覺、工作中不眨）
    /// </summary>
    public double Blink(long time, bool tab = false)
    {
        var face = MoodAt(time);
        if (tab && Mode is MascotMode.Sleep or MascotMode.Work) return 0;
        if (!((Machine.IsOpen || tab) && !IsIntro && (IsStill || (Machine.Playing is null && Mode != MascotMode.Sleep)) && Eyes(time) == MascotEyes.Pill
              && face.Eyes() is null && face.Lid() < 1 && Pose(time)[MascotProp.Dash] < 0.1)) return 0;
        var b = Config.Hero.Blink;
        var period = (b.MinGapMs + b.MaxGapMs) / 2;
        var bucket = (long)Math.Floor((double)time / period);
        foreach (var index in new[] { bucket - 1, bucket })
        {
            var local = time - BlinkStart(index);
            if (local < 0 || local >= b.CloseMs + b.HoldMs + b.OpenMs) continue;
            if (local < b.CloseMs) return MascotEase.InCubic.Apply((double)local / b.CloseMs);
            if (local < b.CloseMs + b.HoldMs) return 1;
            return 1 - MascotEase.Out.Apply((double)(local - b.CloseMs - b.HoldMs) / b.OpenMs);
        }
        return 0;
    }

    /// <summary>第 index 次眨眼的開始時間（每段 period 裡依種子偏移）</summary>
    private long BlinkStart(long index)
    {
        var b = Config.Hero.Blink;
        var period = (b.MinGapMs + b.MaxGapMs) / 2;
        var jitter = (b.MaxGapMs - b.MinGapMs) / 2.0;
        return index * period + (long)((MascotRandom.Unit(Seed, unchecked((ulong)index)) - 0.5) * jitter);
    }

    /// <summary>time 之後下一次眨眼開始的時間（展開待著、畫面不動時，排這個時間再開始重畫）</summary>
    public long NextBlink(long time)
    {
        var b = Config.Hero.Blink;
        var period = (b.MinGapMs + b.MaxGapMs) / 2;
        var bucket = (long)Math.Floor((double)time / period);
        long? next = null;
        for (var index = bucket - 1; index <= bucket + 2; index++)
        {
            var start = BlinkStart(index);
            if (start > time && (next is null || start < next)) next = start;
        }
        return next ?? time + period;
    }

    /// <summary>待著時這一刻畫面會不會變：展開時眨眼中、睡覺（呼吸）或工作中（敲鍵盤）；視線還在追游標</summary>
    public bool IsIdleMoving(long time)
    {
        if (Machine.IsOpen)
        {
            if (!IsStill && Mode is MascotMode.Sleep or MascotMode.Work) return true;
            if (Blink(time) > 0) return true;
        }
        return IsGazeMoving(time);
    }

    /// <summary>視線還在往目標轉（而且臉會跟著轉）</summary>
    public bool IsGazeMoving(long time)
    {
        if (Pose(time)[MascotProp.Follow] <= 0.01) return false;
        var now = Gaze(time);
        return Math.Abs(now.Yaw - gazeTarget.Yaw) > 0.002 || Math.Abs(now.Pitch - gazeTarget.Pitch) > 0.002;
    }

    public MascotPanelShape PanelShape(long time) =>
        MascotPanelShape.From(Spring.State(time).Position, MascotBump.Value(time, BumpStart, Config.Panel), Config.Panel);

    /// <summary>額度卡的透明度與上移（浮現、上移；收合時淡出）</summary>
    public (double Opacity, double Offset) Content(long time)
    {
        var p = Config.Panel;
        if (ContentHiddenAt is { } hidden)
        {
            var u = (double)(time - hidden) / p.ContentFadeOutMs;
            return (Math.Max(0, 1 - u), -p.ContentRisePx * Math.Clamp(u, 0, 1));
        }
        if (ContentShownAt is not { } shown || time < shown) return (0, -p.ContentRisePx);
        var fade = Math.Min((double)(time - shown) / p.ContentFadeInMs, 1);
        var rise = MascotEase.Out.Apply((double)(time - shown) / p.ContentRiseMs);
        return (fade, -p.ContentRisePx * (1 - rise));
    }

    /// <summary>這一刻是否還有東西在動（決定每秒 60 次、30 次或停止重畫）</summary>
    public bool IsAnimating(long time)
    {
        if (!Spring.IsSettled(time)) return true;
        if (Script.SettledAt > time) return true;
        if (Ripple is { } ripple && time < ripple.EndTime) return true;
        if (MascotBump.IsActive(time, BumpStart, Config.Panel)) return true;
        if (effects.Any(e => time < e.Start + e.Duration)) return true;
        if (time < statusStart + 400) return true;
        if (ContentShownAt is { } shown && time < shown + Config.Panel.ContentRiseMs) return true;
        if (ContentHiddenAt is { } hidden && time < hidden + Config.Panel.ContentFadeOutMs) return true;
        return !IsStill && Machine.Playing is not null;
    }

    /// <summary>畫面需要持續重畫（眨眼、看滑鼠、晃動、呼吸）：展開時</summary>
    public bool IsLive => Machine.IsOpen;
}
