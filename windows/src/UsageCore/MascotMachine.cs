using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIUsageMonitor.Core;

// 角色（mascot）的動畫鎖與排隊（ADR-0016、MASCOT-SPEC 第 6 節）。純邏輯、不碰時鐘：時間由呼叫端以毫秒傳入，
// 同一串事件一定排出同樣的播放順序。和 Mac 的 UsageKit/MascotMachine.swift 是同一份規則，兩邊以
// fixtures/mascot 的 golden 比對；改規則時兩邊一起改。

/// <summary>動畫（一次只播一個）。選單的「表情」每個表情是各自的動畫（FaceHappy…），排隊與取代照一般規則，
/// 播到才換表情（Codex C-02）</summary>
public enum MascotAnimation
{
    Hop, Wave, Nod, Tilt, Giggle, Look, Dizzy, Shy, Scared, Pinch, Squeeze, Wake, Alert,
    FaceHappy, FaceWorried, FaceSad, FaceSick, FaceSurprised, FaceOut, FaceStale,
}

/// <summary>按鈕（右鍵選單）或狀態觸發的動畫：播放中就排隊，只保留最後一個。短反應（Hop、Wave、Nod、Tilt、Giggle、Look）
/// 也是單擊的隨機反應；Pinch 是選單的「捏一下」，Face… 是選單的「表情」（每個表情各自一個要求）</summary>
public enum MascotRequest
{
    Hop, Wave, Nod, Tilt, Giggle, Look, Dizzy, Shy, Scared, Pinch, Alert,
    FaceHappy, FaceWorried, FaceSad, FaceSick, FaceSurprised, FaceOut, FaceStale,
}

public static class MascotRequests
{
    /// <summary>單擊時隨機挑的短反應（可以被連點 5 下打斷）</summary>
    public static readonly IReadOnlyList<MascotRequest> Taps =
        [MascotRequest.Hop, MascotRequest.Wave, MascotRequest.Nod, MascotRequest.Tilt, MascotRequest.Giggle, MascotRequest.Look];

    public static MascotAnimation Animation(this MascotRequest request) => Enum.Parse<MascotAnimation>(request.ToString());

    public static MascotAnimationKind Kind(this MascotRequest request) =>
        Taps.Contains(request) ? MascotAnimationKind.Tap : MascotAnimationKind.Long;
}

/// <summary>手勢：播放中直接忽略。繞圈 → 轉暈、甩動 → 嚇到、停留 → 害羞</summary>
public enum MascotGesture { Circle, Shake, Hover }

/// <summary>模式和動畫是兩回事：動畫播完回到目前模式的姿勢。模式由 AI 的狀態決定（工作中優先於睡覺），不看滑鼠</summary>
public enum MascotMode { None, Sleep, Work }

/// <summary>短反應可以被連點 5 下打斷，長動畫中的點擊不計次</summary>
public enum MascotAnimationKind { Tap, Long, Hold }

public static class MascotNames
{
    /// <summary>golden 與設定檔用的小寫名稱（和 Swift 的 rawValue 相同）</summary>
    public static string Name<T>(T value) where T : Enum => value.ToString().ToLowerInvariant();

    public static T Parse<T>(string name) where T : struct, Enum =>
        Enum.TryParse<T>(name, ignoreCase: true, out var value) && Name(value) == name
            ? value
            : throw new ArgumentException($"未知的名稱 {name}");
}

/// <summary>狀態機用到的時間（shared/mascot-anim.json 的 machine）</summary>
public sealed record MascotTiming
{
    [JsonPropertyName("rest_before_queued_ms"), JsonRequired] public required int RestBeforeQueuedMs { get; init; }
    [JsonPropertyName("click_window_ms"), JsonRequired] public required int ClickWindowMs { get; init; }
    [JsonPropertyName("clicks_for_dizzy"), JsonRequired] public required int ClicksForDizzy { get; init; }
    [JsonPropertyName("hold_ms"), JsonRequired] public required int HoldMs { get; init; }
    [JsonPropertyName("intro_interactive_ms"), JsonRequired] public required int IntroInteractiveMs { get; init; }
    [JsonPropertyName("durations_ms"), JsonRequired] public required Dictionary<string, int> DurationsMs { get; init; }

    private sealed record ConfigFile([property: JsonPropertyName("machine")] MascotTiming Machine);

    /// <summary>讀整份 mascot-anim.json，取出 machine</summary>
    public static MascotTiming FromConfig(string json) =>
        JsonSerializer.Deserialize<ConfigFile>(json)?.Machine ?? throw new JsonException("mascot-anim.json 缺少 machine");

    /// <summary>動畫長度；捏扁是放開後的長度</summary>
    public int Duration(MascotAnimation animation)
    {
        return DurationsMs.TryGetValue(DurationKey(animation), out var ms) ? ms : 1000;
    }

    /// <summary>設定檔裡的長度鍵（捏扁是放開後的長度；表情都用 face）</summary>
    public static string DurationKey(MascotAnimation animation) =>
        animation == MascotAnimation.Squeeze ? "squeeze_release"
            : animation.ToString().StartsWith("Face", StringComparison.Ordinal) ? "face" : MascotNames.Name(animation);
}

/// <summary>播放中的動畫；End 為 null 表示按住捏扁中（放開後才有結束時間）</summary>
public sealed record MascotPlaying(MascotAnimation Animation, MascotAnimationKind Kind, long Start, long? End);

/// <summary>狀態機的事件（畫面依它換腳本；golden 比對它的文字，和 Swift 的 MascotEvent 相同）</summary>
public abstract record MascotEvent
{
    public sealed record Open(bool Intro) : MascotEvent { public override string ToString() => Intro ? "open intro" : "open quick"; }
    public sealed record Close : MascotEvent { public override string ToString() => "close"; }
    public sealed record IntroEnd : MascotEvent { public override string ToString() => "intro-end"; }
    public sealed record Start(MascotAnimation Animation) : MascotEvent { public override string ToString() => $"start {MascotNames.Name(Animation)}"; }
    public sealed record End(MascotAnimation Animation) : MascotEvent { public override string ToString() => $"end {MascotNames.Name(Animation)}"; }
    public sealed record Interrupt(MascotAnimation Animation) : MascotEvent { public override string ToString() => $"interrupt {MascotNames.Name(Animation)}"; }
    public sealed record Release : MascotEvent { public override string ToString() => "release squeeze"; }
    public sealed record Pose(MascotMode Mode) : MascotEvent { public override string ToString() => $"pose {MascotNames.Name(Mode)}"; }
    public sealed record ModeChanged(MascotMode Mode) : MascotEvent { public override string ToString() => $"mode {MascotNames.Name(Mode)}"; }
    public sealed record Queue(MascotRequest Request) : MascotEvent { public override string ToString() => $"queue {MascotNames.Name(Request)}"; }
    public sealed record Drop(MascotRequest Request) : MascotEvent { public override string ToString() => $"drop {MascotNames.Name(Request)}"; }
    public sealed record Ignore(string Name) : MascotEvent { public override string ToString() => $"ignore {Name}"; }
    public sealed record Status(int Level) : MascotEvent { public override string ToString() => $"status {Level}"; }
    public sealed record Bump : MascotEvent { public override string ToString() => "bump"; }
}

/// <summary>事件紀錄的一行：golden 比對與畫面換腳本用</summary>
public readonly record struct MascotLogEntry(long Time, MascotEvent Event)
{
    public override string ToString() => $"{Time} {Event}";
}

public sealed class MascotMachine
{
    private enum Step { End, Queued, Hold, Intro }

    private readonly List<MascotLogEntry> log = [];
    private readonly List<long> clicks = [];
    private long? holdArmAt;
    private bool justReleased;

    /// <summary>statusLevel 是啟動時已知的額度狀態（不會因此鼓一下或播提醒）</summary>
    public MascotMachine(MascotTiming timing, long startTime = 0, int statusLevel = 0)
    {
        Timing = timing;
        Now = startTime;
        StatusLevel = statusLevel;
    }

    public MascotTiming Timing { get; }
    /// <summary>狀態機的目前時間（已處理到的最後一刻；只會往前）</summary>
    public long Now { get; private set; }
    public bool IsOpen { get; private set; }
    /// <summary>過場結束（開始接受互動）的時間；不在過場中為 null</summary>
    public long? IntroUntil { get; private set; }
    public MascotMode Mode { get; private set; } = MascotMode.None;
    public MascotPlaying? Playing { get; private set; }
    /// <summary>播完、回到原本姿勢後才播排隊的；這段期間仍算忙碌</summary>
    public long? RestUntil { get; private set; }
    /// <summary>回位等待中、已經從隊伍取出、接著要播的（demo 的 finish：播完那一刻就取出）</summary>
    public MascotRequest? Pending { get; private set; }
    /// <summary>排隊中的（只留最後一個）</summary>
    public MascotRequest? Queued { get; private set; }
    public bool IsHolding { get; private set; }
    public int StatusLevel { get; private set; }
    /// <summary>最近一次動畫結束、回到模式姿勢的時間（畫面用來做 .32 秒的回位）</summary>
    public long? RestedAt { get; private set; }
    public IReadOnlyList<MascotLogEntry> Log => log;
    /// <summary>AI 正在跑（工作中）</summary>
    public bool IsWorking { get; private set; }
    /// <summary>Claude 與 Codex 都閒置超過設定的時間（睡覺）；工作中優先</summary>
    public bool IsAgentIdle { get; private set; }

    public bool IsIntro => IntroUntil is not null;
    public bool IsBusy => Playing is not null || RestUntil is not null;
    private bool IsBusyWithLong => IsBusy && Playing?.Kind != MascotAnimationKind.Tap;

    /// <summary>下一個到期的時間（App 依它排一次計時器呼叫 Advance，不輪詢）</summary>
    public long? NextDeadline => NextDue(long.MaxValue)?.Item1;

    /// <summary>只保留最後幾行紀錄（App 長時間執行時用；golden 不需要）</summary>
    public void TrimLog(int keeping = 0) => log.RemoveRange(0, Math.Max(log.Count - keeping, 0));

    // ── 時間 ──

    /// <summary>處理到 time 之前到期的所有事（動畫結束、排隊開始、按住成立、過場結束）；時間不會倒退</summary>
    public void Advance(long time)
    {
        while (NextDue(time) is (var at, var step))
        {
            Now = Math.Max(Now, at);
            switch (step)
            {
                case Step.End: EndPlaying(); break;
                case Step.Queued: StartPending(); break;
                case Step.Hold: ArmHold(); break;
                case Step.Intro: FinishIntro(); break;
            }
        }
        Now = Math.Max(Now, time);
    }

    /// <summary>每個事件的入口：先處理到期的事，事件時間比狀態機的時間早（不同時鐘的小誤差）時以目前時間為準</summary>
    private long Begin(long time)
    {
        Advance(time);
        return Now;
    }

    private (long, Step)? NextDue(long time)
    {
        (long, Step)? best = null;
        void Consider(long? at, Step step)
        {
            if (at is not { } value || value > time) return;
            if (best is not { } b || value < b.Item1 || (value == b.Item1 && step < b.Item2)) best = (value, step);
        }
        Consider(Playing?.End, Step.End);
        Consider(RestUntil, Step.Queued);
        Consider(holdArmAt, Step.Hold);
        Consider(IntroUntil, Step.Intro);
        return best;
    }

    // ── 事件 ──

    public void Open(long time, bool intro)
    {
        time = Begin(time);
        if (IsOpen) return;
        IsOpen = true;
        clicks.Clear();
        if (intro) IntroUntil = time + Timing.IntroInteractiveMs;
        Record(new MascotEvent.Open(intro));
    }

    public void Close(long time)
    {
        Begin(time);
        if (!IsOpen) return;
        IsOpen = false;
        if (Playing is { } playing) Record(new MascotEvent.Interrupt(playing.Animation));
        Playing = null;
        RestUntil = null;
        IntroUntil = null;
        DropPending();
        DropQueued();
        IsHolding = false;
        holdArmAt = null;
        justReleased = false;
        clicks.Clear();
        Record(new MascotEvent.Close());
    }

    /// <summary>按鈕或狀態觸發：忙碌（過場、播放中、回位中、按住）就排隊，只留最後一個；面板收著時丟掉</summary>
    public void Request(MascotRequest request, long time)
    {
        Begin(time);
        if (!IsOpen)
        {
            Record(new MascotEvent.Drop(request));
            return;
        }
        if (IsIntro || IsBusy || IsHolding)
        {
            DropQueued();
            Queued = request;
            Record(new MascotEvent.Queue(request));
        }
        else
        {
            Run(request);
        }
    }

    /// <summary>手勢：忙碌時直接忽略，不排隊</summary>
    public void Gesture(MascotGesture gesture, long time)
    {
        Begin(time);
        if (!IsOpen || IsIntro || IsBusy || IsHolding || Mode == MascotMode.Sleep)
        {
            Record(new MascotEvent.Ignore(MascotNames.Name(gesture)));
            return;
        }
        Run(gesture switch
        {
            MascotGesture.Circle => MascotRequest.Dizzy,
            MascotGesture.Shake => MascotRequest.Scared,
            _ => MascotRequest.Shy,
        });
    }

    /// <summary>點角色：choice 是這次的隨機反應（呼叫端決定，golden 才能重現）</summary>
    public void Click(long time, MascotRequest choice)
    {
        time = Begin(time);
        if (!IsOpen || IsIntro) return;
        if (justReleased)
        {
            justReleased = false;
            return;
        }
        // 睡覺時點一下：叫醒一下（播完回到睡覺的姿勢；睡不睡由 AI 的狀態決定）
        if (Mode == MascotMode.Sleep && !IsBusy)
        {
            Start(MascotAnimation.Wake, MascotAnimationKind.Long);
            return;
        }
        // 長動畫（含按住、回位中）裡的點擊不計次
        if (IsBusyWithLong)
        {
            clicks.Clear();
            return;
        }
        clicks.RemoveAll(c => time - c > Timing.ClickWindowMs);
        clicks.Add(time);
        if (clicks.Count >= Timing.ClicksForDizzy)
        {
            // 唯一能插隊的例外：短反應中連點 5 下直接轉暈
            clicks.Clear();
            DropQueued();
            Run(MascotRequest.Dizzy);
            return;
        }
        if (IsBusy) return;
        Run(choice);
    }

    public void Press(long time)
    {
        time = Begin(time);
        if (!IsOpen || IsIntro || IsBusyWithLong) return;
        justReleased = false;
        holdArmAt = time + Timing.HoldMs;
    }

    public void Release(long time)
    {
        time = Begin(time);
        holdArmAt = null;
        if (!IsHolding) return;
        IsHolding = false;
        justReleased = true;
        if (Playing is { Kind: MascotAnimationKind.Hold } playing)
        {
            Playing = playing with { End = time + Timing.Duration(MascotAnimation.Squeeze) };
            Record(new MascotEvent.Release());
        }
    }

    /// <summary>滑鼠在面板裡移動：只推進時間。睡不睡由 AI 的狀態決定，動滑鼠不會叫醒</summary>
    public void Move(long time) => Begin(time);

    /// <summary>工作中：狀態立即生效（姿勢在沒有動畫時馬上換）；工作中優先於睡覺</summary>
    public void SetWorking(bool working, long time)
    {
        Begin(time);
        IsWorking = working;
        UpdateMode();
    }

    /// <summary>Claude 與 Codex 都閒置超過設定的時間：睡覺（面板收著也算，迷你角色顯示睡著的姿勢）</summary>
    public void SetAgentIdle(bool idle, long time)
    {
        Begin(time);
        IsAgentIdle = idle;
        UpdateMode();
    }

    private void UpdateMode() => SetMode(IsWorking ? MascotMode.Work : IsAgentIdle ? MascotMode.Sleep : MascotMode.None);

    /// <summary>額度狀態（0 正常、1 偏高、2 用完或出錯）：表情立即換，提醒動畫排隊；收著時改成瀏海鼓一下；
    /// 回到正常只換表情，排隊中的提醒也丟掉。react 為 false（靜音、勿擾）時只換表情、不播也不鼓</summary>
    public void SetStatus(int level, long time, bool react = true)
    {
        time = Begin(time);
        if (level == StatusLevel) return;
        StatusLevel = level;
        Record(new MascotEvent.Status(level));
        if (level <= 0 || !react)
        {
            if (Queued == MascotRequest.Alert) DropQueued();
            if (Pending == MascotRequest.Alert) DropPending();
            return;
        }
        if (IsOpen) Request(MascotRequest.Alert, time);
        else Record(new MascotEvent.Bump());
    }

    // ── 內部 ──

    /// <summary>睡覺中也照樣播（每個動畫從中性姿勢開始），播完回到睡覺的姿勢</summary>
    private void Run(MascotRequest request)
    {
        RestUntil = null;
        Start(request.Animation(), request.Kind());
    }

    /// <summary>每個動畫開始前先歸零（畫面依 Playing.Start 從中性姿勢開始），被取代的記為 interrupt</summary>
    private void Start(MascotAnimation animation, MascotAnimationKind kind)
    {
        if (Playing is { } playing) Record(new MascotEvent.Interrupt(playing.Animation));
        long? end = kind == MascotAnimationKind.Hold ? null : Now + Timing.Duration(animation);
        Playing = new MascotPlaying(animation, kind, Now, end);
        Record(new MascotEvent.Start(animation));
    }

    /// <summary>播完：回到模式姿勢；有排隊的就在這一刻取出，回位 360 ms 後播（回位期間再來的要求另外排隊）</summary>
    private void EndPlaying()
    {
        if (Playing is not { } finished) return;
        Playing = null;
        Record(new MascotEvent.End(finished.Animation));
        RestedAt = Now;
        Record(new MascotEvent.Pose(Mode));
        if (Queued is { } next)
        {
            Queued = null;
            Pending = next;
            RestUntil = Now + Timing.RestBeforeQueuedMs;
        }
    }

    private void StartPending()
    {
        RestUntil = null;
        if (Pending is { } next)
        {
            Pending = null;
            Run(next);
        }
        PromoteQueued();
    }

    /// <summary>沒有動畫在播（待播的被取消、或執行的是沒有結束事件的睡覺）卻還有排隊的：照樣回位 360 ms 後播，不會卡住</summary>
    private void PromoteQueued()
    {
        if (IsBusy || IsHolding || Queued is not { } next) return;
        Queued = null;
        Pending = next;
        RestUntil = Now + Timing.RestBeforeQueuedMs;
    }

    private void ArmHold()
    {
        holdArmAt = null;
        if (!IsOpen || IsIntro || IsBusyWithLong) return;
        IsHolding = true;
        RestUntil = null;
        DropPending();
        Start(MascotAnimation.Squeeze, MascotAnimationKind.Hold);
    }

    private void FinishIntro()
    {
        IntroUntil = null;
        Record(new MascotEvent.IntroEnd());
        if (Queued is not { } next) return;
        Queued = null;
        Run(next);
    }

    private void DropQueued()
    {
        if (Queued is { } queued) Record(new MascotEvent.Drop(queued));
        Queued = null;
    }

    private void DropPending()
    {
        if (Pending is { } pending) Record(new MascotEvent.Drop(pending));
        Pending = null;
    }

    private void SetMode(MascotMode mode)
    {
        if (Mode == mode) return;
        Mode = mode;
        Record(new MascotEvent.ModeChanged(mode));
    }

    private void Record(MascotEvent e) => log.Add(new MascotLogEntry(Now, e));
}
