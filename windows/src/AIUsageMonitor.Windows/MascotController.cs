using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Threading;
using AIUsageMonitor.Core;
using AIUsageMonitor.Mascot;

namespace AIUsageMonitor.Windows;

/// <summary>重畫的頻率（同 Mac 的 MascotRenderRate，ADR-0015 第 7 節「角色」）</summary>
internal enum MascotRenderRate { Stopped, Effect, Breathing, Gaze, Idle, Animating }

internal static class MascotRenderRates
{
    public static double IntervalMs(this MascotRenderRate rate) => rate switch
    {
        MascotRenderRate.Breathing => 1000.0 / 10,
        MascotRenderRate.Gaze => 1000.0 / 15,
        MascotRenderRate.Effect => 1000.0 / 12,
        MascotRenderRate.Animating => 1000.0 / 60,
        _ => 1000.0 / 30,
    };
}

/// <summary>
/// 懸浮圖示是「角色」時的狀態（同 Mac 的 MascotController，ADR-0016、ADR-0015 第 7 節「角色」）。狀態機與畫面在 UsageCore 的
/// <see cref="MascotDirector"/>；這裡負責時間基準、到期時叫 Advance、決定重畫的頻率（只有一個重畫用的 DispatcherTimer，不需要時停止）、
/// 看滑鼠（GetCursorPos 輪詢，不裝鉤子）、看 AI 紀錄資料夾的修改時間（不讀內容），以及把設定、額度與 AI 的狀態接進去。
/// 圖示隱藏（全螢幕、只顯示系統匣）時 <see cref="SetShown"/>(false) 停掉所有計時器。
/// </summary>
internal sealed class MascotController : IDisposable
{
    private readonly AppSettings settings;
    // 截圖（DebugTools）時沒有 AI 狀態與資料：null
    private readonly AgentMonitor? agents;
    private readonly UsageStore? store;
#if DEBUG
    /// <summary>截圖用的固定時間（毫秒）</summary>
    private long? fixedTime;
#endif
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly DispatcherTimer frameTimer;
    private readonly DispatcherTimer deadlineTimer;
    private readonly DispatcherTimer rateTimer;
    private readonly DispatcherTimer gazeTimer;
    private readonly DispatcherTimer workTimer;
    private readonly DispatcherTimer hoverTimer;
    private readonly DispatcherTimer pulseTimer;
    private MascotGestureDetector? gestures;
    private bool shown;
    private bool disposed;
    /// <summary>外觀的特效正在動；特效自己的時鐘停住時停在最後一格（同 Mac 的 effectBase）</summary>
    private bool effectsLive;
    private long effectBase;
    private long effectStart;
    private bool playedIntro;
    private bool menuOpen;
    private bool pressedOnCharacter;
    private bool probing;
    private int probeGeneration;
    private Dictionary<AgentKind, (bool Working, bool Active)> fallbackActivity = [];
    private (double X, double Y)? lastPointer;
    private int pointerStillTicks;
    private bool gazeDozing;
    private MascotMotionLevel builtMotion;

    public MascotController(AppSettings settings, AgentMonitor? agents, UsageStore? store, Dispatcher dispatcher)
    {
        this.settings = settings;
        this.agents = agents;
        this.store = store;
        SyncIdleAfter();
        Config = LoadConfig();
        Looks = LoadLooks();
        Painter = new MascotPainter(Config);
        frameTimer = Timer(dispatcher, DispatcherPriority.Render, () => Changed?.Invoke());
        deadlineTimer = OneShot(dispatcher, () => Mutate(d => d.Advance(Time())));
        rateTimer = OneShot(dispatcher, Refresh);
        gazeTimer = Timer(dispatcher, DispatcherPriority.Background, PollPointer);
        workTimer = Timer(dispatcher, DispatcherPriority.Background, CheckWorking);
        hoverTimer = OneShot(dispatcher, HoverDue);
        pulseTimer = Timer(dispatcher, DispatcherPriority.Background, Pulse);
        Rebuild();
    }

    public MascotConfig Config { get; }
    public MascotLooks? Looks { get; }
    public MascotPainter Painter { get; }
    public MascotDirector? Director { get; private set; }
    public MascotRenderRate Rate { get; private set; } = MascotRenderRate.Stopped;
    /// <summary>不在動畫中時畫的那一刻（毫秒）：完全停止時角色停在這一刻，不會停在眨眼一半</summary>
    public long StoppedAt { get; private set; }
    /// <summary>保持展開：滑鼠離開也不收合</summary>
    public bool Pinned { get; private set; }
    /// <summary>收合時循環播放的一輪（AI 工作中、睡著）；null 是沒有</summary>
    public MascotCollapsedMotion? Loop { get; private set; }
    /// <summary>目前循環的那一輪依什麼畫（任何一個改了就重畫那一輪）</summary>
    public object? LoopKey { get; private set; }
    /// <summary>等你下一個指令時的脈動：這一輪開始的時間（null 是沒在脈動）</summary>
    public long? PulseAt { get; private set; }
    /// <summary>這台電腦的等級（ADR-0020；只看這台，沒有時 null）</summary>
    public int? Level { get; private set; }

    /// <summary>畫面要重畫</summary>
    public event Action? Changed;
    /// <summary>要收合（保持展開取消、設定改變）</summary>
    public event Action? CloseRequested;
    /// <summary>展開了：讀一次等級（ADR-0020 第 4 節）</summary>
    public event Action? Opened;

    /// <summary>圖示中心在螢幕上的位置與 DPI 倍率（實體像素）；圖示沒顯示時 null（看滑鼠用）</summary>
    public Func<(double X, double Y, double Scale)?>? HeroOnScreen { get; set; }
    /// <summary>滑鼠在圖示視窗裡（選單關掉後決定要不要收合）</summary>
    public Func<bool>? ContainsPointer { get; set; }

    public MascotCharacter Character => settings.MascotProvider == "codex" ? MascotCharacter.Codex : MascotCharacter.Claude;
    public MascotLook? Look => Looks?.Look(settings.MascotLook);
    public MascotMotionLevel Motion => MascotMotion.Effective(settings.MascotMotion, SystemLook.AnimationsEnabled);
    public bool IsOpen => Director?.Machine.IsOpen == true;

    /// <summary>毫秒時間基準（單調遞增，不受改系統時間影響）</summary>
#if DEBUG
    public long Time() => fixedTime ?? clock.ElapsedMilliseconds;
#else
    public long Time() => clock.ElapsedMilliseconds;
#endif

#if DEBUG
    /// <summary>截圖：狀態機從時間 0 開始、照 setup 擺好，畫 time 那一刻（計時器不會跑：截圖不進訊息迴圈）</summary>
    public void Shot(long time, Action<MascotDirector> setup, int? level = null, long? pulseAt = null)
    {
        fixedTime = 0;
        Director = new MascotDirector(Config, startTime: 0);
        Director.SetStill(!Motion.AnimatesBody(), 0);
        effectsLive = false;
        effectBase = 0;
        setup(Director);
        fixedTime = time;
        Director.Advance(time);
        Level = level;
        PulseAt = pulseAt;
        shown = true;
        Refresh();
    }
#endif

    /// <summary>特效那一格的時間；null 是靜態的一格（動畫「簡單」「關閉」、不會動的外觀）</summary>
    public long? EffectTime(long t)
    {
        if (!Motion.AnimatesEffects() || Look?.Style.Animates() != true) return null;
        return effectsLive ? effectBase + Math.Max(t - effectStart, 0) : effectBase;
    }

    /// <summary>某一刻的畫面</summary>
    public MascotFrame? Frame(long t) => Director is { } d
        ? MascotFrames.From(d, t, Character, Look, EffectTime(t), still: !Motion.MovesEyes())
        : null;

    // ---------- 設定檔 ----------

    private static string Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"{name} missing");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static MascotConfig LoadConfig() => MascotConfig.Decode(Resource("mascot-anim.json"));

    public static MascotLooks? LoadLooks()
    {
        try
        {
            return MascotLooks.Decode(Resource("mascot-looks.json"));
        }
        catch (Exception e) when (e is InvalidOperationException or System.Text.Json.JsonException)
        {
            AppLog.Write("mascot-looks.json missing or invalid; only the service colors");
            return null;
        }
    }

    // ---------- 建立與顯示 ----------

    private void Rebuild()
    {
        var config = Config;
        // 簡單、關閉：展開不回彈
        if (Motion != MascotMotionLevel.Full)
        {
            config = config with { Panel = config.Panel with { OpenSpring = config.Panel.OpenSpring with { DampingRatio = 1 } } };
        }
        builtMotion = Motion;
        var t = Time();
        Director = new MascotDirector(config, startTime: t, statusLevel: Director?.Machine.StatusLevel ?? 0);
        Director.SetStill(!Motion.AnimatesBody(), t);
        gestures = new MascotGestureDetector(config);
        pressedOnCharacter = false;
        lastPointer = null;
        RestartActivityChecks();
        UpdateStatus();
        RestartGaze();
        Refresh();
    }

    private bool docked;

    /// <summary>收進貼邊的標籤（或拉出來）：標籤是靜態一格，不重畫、不看滑鼠、不脈動（ADR-0015 第 7 節「角色」）</summary>
    public void SetDocked(bool value)
    {
        if (docked == value) return;
        docked = value;
        RestartGaze();
        UpdatePulse();
        Refresh();
    }

    /// <summary>圖示顯示或隱藏（全螢幕、樣式改成圓環、只顯示系統匣）：隱藏時所有計時器都停</summary>
    public void SetShown(bool value)
    {
        if (shown == value) return;
        shown = value;
        if (!value && IsOpen) CloseNow();
        RestartActivityChecks();
        RestartGaze();
        UpdatePulse();
        Refresh();
    }

    // ---------- 事件 ----------

    /// <summary>滑鼠移入：展開（依設定播過場）</summary>
    public void PointerEntered()
    {
        if (Director is not { } director || director.Machine.IsOpen) return;
        var intro = MascotMotion.ShouldPlayIntro(settings.MascotIntro, Motion, playedIntro);
        if (intro) playedIntro = true;
        director.Open(Time(), intro);
        // 收合時工作中或睡著不看游標（每秒 1 次）：展開一律追
        if (gazeDozing) RestartGaze();
        Refresh();
        RestartActivityChecks();
        UpdatePulse();
        // 展開就算看過了：完成與出錯不再當成新消息（ADR-0017）
        agents?.MarkSeen();
        Opened?.Invoke();
    }

    /// <summary>保持展開：關掉時滑鼠不在圖示上就收</summary>
    public void SetPinned(bool on)
    {
        if (Pinned == on) return;
        Pinned = on;
        if (!on && ContainsPointer?.Invoke() != true) CloseRequested?.Invoke();
    }

    /// <summary>收合（滑鼠離開、點一下打開面板、拖動）</summary>
    public void CloseNow()
    {
        Pinned = false;
        gestures?.Reset();
        hoverTimer.Stop();
        if (pressedOnCharacter)
        {
            pressedOnCharacter = false;
            Mutate(d => d.Release(Time()));
        }
        Mutate(d => d.Close(Time()));
        RestartActivityChecks();
        UpdatePulse();
        // 收合後才依新的動畫程度重建（彈簧在建立時決定）
        if (Motion != builtMotion) Rebuild();
    }

    /// <summary>動畫程度改了（設定、Windows 的「顯示動畫」）</summary>
    public void MotionChanged()
    {
        RestartGaze();
        Mutate(d => d.SetStill(!Motion.AnimatesBody(), Time()));
        if (Motion != builtMotion && !IsOpen) Rebuild();
        UpdatePulse();
        Refresh();
    }

    /// <summary>外觀、角色、睡覺的分鐘數等設定改了</summary>
    public void SettingsChanged()
    {
        SyncIdleAfter();
        MotionChanged();
        UpdateStatus();
        RestartActivityChecks();
        Refresh();
    }

    /// <summary>hook 工作階段多久沒動靜算閒著（睡覺）：照設定的睡覺分鐘數，和沒有 hook 時的紀錄修改時間一致（同 Mac 的 AgentMonitor.idleAfterMs）</summary>
    private void SyncIdleAfter()
    {
        if (agents is not null) agents.Sessions.IdleAfter = settings.MascotSleepMinutes * 60_000L;
    }

    private bool CanDetect(MascotMachine m) =>
        Motion.DetectsGestures() && m.IsOpen && !m.IsIntro && !m.IsBusy && !m.IsHolding && m.Mode != MascotMode.Sleep;

    /// <summary>滑鼠在圖示視窗裡移動（畫布座標）：偵測繞圈、甩動、停留（只在這個視窗裡）</summary>
    public void PointerMoved(double x, double y)
    {
        if (Director is not { } director || gestures is null) return;
        var t = Time();
        var pose = director.Pose(t);
        var gesture = gestures.Move(x, y, t, pose[MascotProp.X], pose[MascotProp.Y], pose[MascotProp.R], CanDetect(director.Machine));
        Mutate(d =>
        {
            d.Move(t);
            if (gesture is { } g) d.Gesture(g, t);
        });
        hoverTimer.Stop();
        if (gestures.HoverDeadline is { } deadline) Start(hoverTimer, deadline - t);
    }

    private void HoverDue()
    {
        if (Director is not { } director || gestures is null) return;
        var t = Time();
        if (gestures.CheckHover(t, CanDetect(director.Machine)) is { } g) Mutate(d => d.Gesture(g, t));
    }

    /// <summary>按下：展開時落在角色上才算（按住捏扁）；回傳是否由角色處理</summary>
    public bool PointerDown(double x, double y)
    {
        if (Director is not { } director || gestures is null || !Motion.AnimatesBody() || !director.Machine.IsOpen) return false;
        var t = Time();
        var pose = director.Pose(t);
        if (!gestures.Hits(x, y, pose[MascotProp.X], pose[MascotProp.Y], pose[MascotProp.R])) return false;
        pressedOnCharacter = true;
        Mutate(d => d.Press(t));
        agents?.MarkSeen();
        return true;
    }

    /// <summary>放開：在角色上放開算一次點擊（從短反應平均隨機挑一個）</summary>
    public void PointerUp(double x, double y)
    {
        if (!pressedOnCharacter || Director is not { } director || gestures is null) return;
        pressedOnCharacter = false;
        var t = Time();
        var pose = director.Pose(t);
        var on = gestures.Hits(x, y, pose[MascotProp.X], pose[MascotProp.Y], pose[MascotProp.R]);
        var choices = director.Config.Interaction.TapReactions
            .Select(name => Enum.TryParse<MascotRequest>(name, ignoreCase: true, out var r) ? r : (MascotRequest?)null).OfType<MascotRequest>().ToList();
        var choice = choices.Count > 0 ? choices[Random.Shared.Next(choices.Count)] : MascotRequest.Hop;
        Mutate(d =>
        {
            d.Release(t);
            if (on) d.Click(t, choice);
        });
    }

    // ---------- 工作中與睡覺（只看紀錄檔的修改時間） ----------

    /// <summary>展開時每 5 秒、收著時每 60 秒（ADR-0016 第 5 節）</summary>
    private void RestartActivityChecks()
    {
        workTimer.Stop();
        probeGeneration++;
        if (Director is null || !shown) return;
        CheckWorking();
        workTimer.Interval = TimeSpan.FromSeconds(IsOpen ? 5 : 60);
        workTimer.Start();
    }

    private void CheckWorking()
    {
        if (probing || !Motion.AnimatesBody() || agents is null) return;
        probing = true;
        var generation = probeGeneration;
        var idleAfter = settings.MascotSleepMinutes * 60.0;
        // 有 hook 工作階段的 AI 照 hook 的狀態，不必再列它的紀錄資料夾（ADR-0017 第 4 節）
        var hooked = new[] { AgentKind.Claude, AgentKind.Codex }.Where(agents.Sessions.Has).ToHashSet();
        Task.Run(() =>
        {
            var now = DateTimeOffset.UtcNow;
            var result = new Dictionary<AgentKind, (bool Working, bool Active)>();
            foreach (var ai in new[] { AgentKind.Claude, AgentKind.Codex })
            {
                if (hooked.Contains(ai)) continue;
                var probe = new MascotActivityProbe([MascotActivityProbe.RootIn(ai, AgentHookInstaller.Directory(ai))]);
                var working = probe.IsWorking(now);
                result[ai] = (working, working || probe.IsActive(idleAfter, now));
            }
            return result;
        }).ContinueWith(task => frameTimer.Dispatcher.BeginInvoke(() =>
        {
            probing = false;
            if (generation != probeGeneration || disposed) return;
            if (!task.IsCompletedSuccessfully)
            {
                AppLog.Write($"mascot activity: {task.Exception?.InnerException?.GetType().Name}");
                return;
            }
            fallbackActivity = task.Result;
            ApplyActivity();
        }));
    }

    /// <summary>hook 的狀態變了：馬上重算工作中、需要你與睡覺，以及表情與脈動</summary>
    public void AgentStateChanged()
    {
        ApplyActivity();
        UpdateStatus();
        UpdatePulse();
    }

    /// <summary>一個回合完成：揮手（收著時鼓一下）。靜音、勿擾時不動；圖示沒顯示時不排動畫</summary>
    public void AgentFinished()
    {
        if (!shown) return;
        var quiet = settings.IsMascotQuiet(DateTimeOffset.Now);
        Mutate(d => d.Cheer(Time(), react: !quiet));
    }

    /// <summary>升級（ADR-0020 第 4 節）：展開時跳一下再開心；收著、靜音、其他動作中時不播</summary>
    public void LevelChanged(int? level)
    {
        var before = Level;
        Level = level;
        Changed?.Invoke();
        if (before is not { } old || level is not { } now || now <= old) return;
        if (!shown || Director is not { } d || !d.Machine.IsOpen || settings.IsMascotQuiet(DateTimeOffset.Now) || !Motion.AnimatesBody()) return;
        if (d.Machine.IsIntro || d.Machine.IsBusy || d.Machine.IsHolding) return;
        Mutate(x =>
        {
            x.Request(MascotRequest.Hop, Time());
            x.Request(MascotRequest.FaceHappy, Time());
        });
    }

    private void ApplyActivity()
    {
        if (!Motion.AnimatesBody() || Director is not { } director || agents is null) return;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var (working, idle) = agents.Sessions.Activity(now, fallbackActivity);
        var needsYou = agents.Sessions.Count(AgentState.NeedsYou, now) > 0;
        var m = director.Machine;
        if (m.IsWorking == working && m.IsAgentIdle == idle && m.IsNeedsYou == needsYou) return;
        Mutate(d =>
        {
            d.SetWorking(working, Time());
            d.SetAgentIdle(idle, Time());
            d.SetNeedsYou(needsYou, Time());
        });
    }

    /// <summary>依目前的快照與角色更新表情與額度狀態（讀到新資料、每分鐘、換角色時）</summary>
    public void UpdateStatus()
    {
        if (Director is not { } director || store is null || agents is null) return;
        var snapshot = store.Snapshot;
        var now = Clock.Now;
        var provider = Character.Provider();
        var level = StatusLevel(snapshot, provider, now);
        var quota = MascotMoods.Quota(level, MascotMoods.IsQuotaUnavailable(snapshot, provider, store.Error is not null, now),
            MascotMoods.HasIncident(snapshot, provider), MascotMoods.RunsOut(snapshot, provider, now));
        var ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var mood = MascotMoods.Agent(agents.Sessions.Top(ms)?.State(ms, agents.Sessions.IdleAfter), quota);
        if (director.Mood != mood) Mutate(d => d.SetMood(mood));
        if (director.Machine.StatusLevel != level)
        {
            var quiet = settings.IsMascotQuiet(DateTimeOffset.Now);
            Mutate(d => d.SetStatus(level, Time(), react: !quiet));
        }
        UpdatePulse();
        Refresh();
    }

    /// <summary>額度的等級：出錯或用完 2、剩不到 20% 1、其他 0（同 Mac 的 NotchQuota.statusLevel）</summary>
    public static int StatusLevel(UsageSnapshot? snapshot, string provider, DateTimeOffset now)
    {
        if (snapshot is null || !snapshot.Providers.TryGetValue(provider, out var usage)) return 0;
        if (usage.Error is not null) return 2;
        var remaining = usage.VisibleWindows.Select(w => w.EffectiveRemainingPct(now)).DefaultIfEmpty(double.NaN).Min();
        if (double.IsNaN(remaining)) return 0;
        if (remaining <= 0) return 2;
        return remaining < Severity.CriticalBelow ? 1 : 0;
    }

    // ---------- 右鍵選單 ----------

    public void Play(MascotRequest request) => Mutate(d => d.Request(request, Time()));

    public void PlayFace(MascotMood mood) => Mutate(d => d.RequestFace(mood, Time()));

    public void MenuOpened() => menuOpen = true;

    public void MenuClosed()
    {
        menuOpen = false;
        if (!Pinned && ContainsPointer?.Invoke() != true) CloseRequested?.Invoke();
    }

    /// <summary>選單開著或保持展開時，滑鼠離開也不收</summary>
    public bool KeepsOpen => Pinned || menuOpen;

    /// <summary>靜音 1 小時／勿擾到明天早上 8 點／取消</summary>
    public void SetQuiet(DateTimeOffset? until)
    {
        settings.MascotQuietUntil = until;
        SettingsFile.Save(settings);
        // 開始靜音：已經排隊的提醒也不播
        if (until is not null) Mutate(d => d.Silence(Time()));
        UpdatePulse();
    }

    // ---------- 等你的脈動（每 7 秒一次、1.6 秒） ----------

    public const int PulseEveryMs = 7000;
    public const int PulseMs = 1600;

    private void UpdatePulse()
    {
        var ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var wanted = agents is not null && settings.MascotWaitingPulse && shown && !docked && !IsOpen && Motion != MascotMotionLevel.Off && SystemLook.AnimationsEnabled
            && !settings.IsMascotQuiet(DateTimeOffset.Now)
            && agents.Sessions.Top(ms)?.State(ms, agents.Sessions.IdleAfter) == AgentState.Waiting;
        if (wanted == pulseTimer.IsEnabled) return;
        if (wanted)
        {
            pulseTimer.Interval = TimeSpan.FromMilliseconds(PulseEveryMs);
            pulseTimer.Start();
            Pulse();
        }
        else
        {
            pulseTimer.Stop();
            PulseAt = null;
            Refresh();
        }
    }

    /// <summary>一次脈動：重畫 1.6 秒（每秒 30 次），之後停到下一次</summary>
    private void Pulse()
    {
        PulseAt = Time();
        Refresh();
    }

    public static double PulseOpacity(double phase)
    {
        var k = phase is < 0 or > 1 ? 0 : Math.Sin(phase * Math.PI);
        return 0.3 * k * k;
    }

    // ---------- 看滑鼠（整個螢幕） ----------

    /// <summary>游標有動時每秒約 12 次、停住 1 秒後 4 次；收合時工作中或睡著每秒 1 次（只看是否又該追游標）</summary>
    private void RestartGaze()
    {
        gazeTimer.Stop();
        lastPointer = null;
        pointerStillTicks = 0;
        gazeDozing = false;
        if (!settings.MascotFollowPointer || !Motion.MovesEyes() || Director is null || !shown || docked)
        {
            if (Director is { } d && d.Look(Time(), 0, 0, threshold: 0.001)) Refresh();
            return;
        }
        ScheduleGaze(1000.0 / 12);
    }

    private void ScheduleGaze(double ms)
    {
        gazeTimer.Interval = TimeSpan.FromMilliseconds(ms);
        gazeTimer.Start();
    }

    /// <summary>視線的門檻（弧度）：游標小小移動不重畫</summary>
    private const double GazeThreshold = 0.02;

    private void PollPointer()
    {
        if (Director is not { } director) return;
        if (!director.Machine.FollowsPointer)
        {
            // 直接轉到正前方，敲鍵盤與呼吸的循環才不會被打斷
            if (director.Look(Time(), 0, 0, threshold: 0.001, snap: true))
            {
                lastPointer = null;
                Refresh();
            }
            if (!gazeDozing)
            {
                gazeDozing = true;
                ScheduleGaze(1000);
            }
            return;
        }
        if (gazeDozing)
        {
            gazeDozing = false;
            pointerStillTicks = 0;
            ScheduleGaze(1000.0 / 12);
        }
        if (HeroOnScreen?.Invoke() is not { } hero || !NativeMethods.GetCursorPos(out var cursor)) return;
        var t = Time();
        if (director.Pose(t)[MascotProp.Follow] <= 0.01)
        {
            lastPointer = null;
            return;
        }
        // 游標相對圖示的位置（DIP）：游標沒動但圖示移動（拖動、展開）時也會重新對準
        var dx = (cursor.X - hero.X) / hero.Scale;
        var dy = (cursor.Y - hero.Y) / hero.Scale;
        if (lastPointer is { } last && Math.Abs(last.X - dx) < 0.01 && Math.Abs(last.Y - dy) < 0.01)
        {
            pointerStillTicks++;
            if (pointerStillTicks == 12) ScheduleGaze(250);
            return;
        }
        if (pointerStillTicks >= 12) ScheduleGaze(1000.0 / 12);
        pointerStillTicks = 0;
        lastPointer = (dx, dy);
        if (director.Look(t, dx, dy, GazeThreshold)) Refresh();
    }

    // ---------- 到期與重畫頻率 ----------

    public void Mutate(Action<MascotDirector> body)
    {
        if (Director is not { } director) return;
        body(director);
        Refresh();
        // 收合時工作結束、醒來：又要看游標了，馬上回到每秒 12 次
        if (gazeDozing && director.Machine.FollowsPointer) RestartGaze();
    }

    /// <summary>依狀態機的下一個到期時間排一次計時器（不輪詢）；並決定重畫頻率（同 Mac 的 refresh）</summary>
    public void Refresh()
    {
        deadlineTimer.Stop();
        rateTimer.Stop();
        if (Director is not { } director || !shown)
        {
            SetRate(MascotRenderRate.Stopped, null);
            return;
        }
        var now = Time();
        if (director.NextDeadline is { } deadline) Start(deadlineTimer, deadline - now);
        if (docked && !director.Machine.IsOpen)
        {
            // 標籤只畫停住的一格：狀態機照常到期，但不重畫
            if (Rate != MascotRenderRate.Stopped) StoppedAt = now;
            SetRate(MascotRenderRate.Stopped, null);
            Changed?.Invoke();
            return;
        }
        var animating = director.IsAnimating(now);
        var motion = Motion;
        var live = director.IsLive && motion.MovesEyes();
        var idleMoving = motion.MovesEyes() && director.IsIdleMoving(now);
        var breathing = live && director.Mode == MascotMode.Sleep && !director.IsStill && director.Blink(now) == 0;
        var gazeOnly = idleMoving && !breathing && director.Blink(now) == 0
            && !(live && !director.IsStill && director.Mode == MascotMode.Work);
        var effects = motion.AnimatesEffects() && Look?.Style.Animates() == true
            && (director.Machine.IsOpen || animating || (director.Mode == MascotMode.Work && !director.IsStill));
        if (effects != effectsLive)
        {
            if (effects) effectStart = now;
            else effectBase += Math.Max(now - effectStart, 0);
            effectsLive = effects;
        }
        var rate = animating ? MascotRenderRate.Animating
            : !idleMoving ? MascotRenderRate.Stopped
            : breathing ? MascotRenderRate.Breathing
            : gazeOnly ? MascotRenderRate.Gaze : MascotRenderRate.Idle;
        var collapsedMotion = motion.AnimatesEffects() && !director.Machine.IsOpen && !animating && !director.IsStill
            && director.Mode is MascotMode.Work or MascotMode.Sleep;
        if ((effects || collapsedMotion) && rate == MascotRenderRate.Stopped) rate = MascotRenderRate.Effect;
        if (rate != Rate && rate != MascotRenderRate.Animating) StoppedAt = now;
        // 收合時的一輪：AI 工作中、睡著或特效外觀在動
        MascotCollapsedMotion? loop = null;
        object? key = null;
        if (rate == MascotRenderRate.Effect && !director.Machine.IsOpen)
        {
            key = (director.Mode, director.Mood, director.Machine.StatusLevel, Character, Look?.Id, motion);
            loop = key.Equals(LoopKey) ? Loop
                : MascotCollapsedMotion.Plan(director, StoppedAt, Character, Look, director.Mode == MascotMode.Sleep ? EffectTime(now) : null);
        }
        // 脈動的那 1.6 秒照每秒 30 次重畫
        var pulsing = PulseAt is { } p && now - p < PulseMs;
        SetRate(pulsing && rate == MascotRenderRate.Stopped ? MascotRenderRate.Idle : rate, loop, key);
        if (pulsing) Start(rateTimer, PulseMs - (now - PulseAt!.Value) + 10);
        else if (live && rate is MascotRenderRate.Stopped or MascotRenderRate.Effect) Start(rateTimer, director.NextBlink(now) - now);
        else if (rate is not (MascotRenderRate.Stopped or MascotRenderRate.Effect)) Start(rateTimer, 250);
        Changed?.Invoke();
    }

    private void SetRate(MascotRenderRate rate, MascotCollapsedMotion? loop, object? key = null)
    {
        Rate = rate;
        Loop = loop;
        LoopKey = key;
        var interval = loop is not null ? 1000.0 / loop.Fps : rate == MascotRenderRate.Stopped ? 0 : rate.IntervalMs();
        if (interval <= 0)
        {
            frameTimer.Stop();
            return;
        }
        var span = TimeSpan.FromMilliseconds(interval);
        if (frameTimer.IsEnabled && frameTimer.Interval == span) return;
        frameTimer.Interval = span;
        frameTimer.Start();
    }

    private static DispatcherTimer Timer(Dispatcher dispatcher, DispatcherPriority priority, Action tick)
    {
        var timer = new DispatcherTimer(priority, dispatcher);
        timer.Tick += (_, _) => tick();
        return timer;
    }

    private static DispatcherTimer OneShot(Dispatcher dispatcher, Action tick)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher);
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            tick();
        };
        return timer;
    }

    private static void Start(DispatcherTimer timer, long ms)
    {
        timer.Stop();
        timer.Interval = TimeSpan.FromMilliseconds(Math.Max(ms, 1));
        timer.Start();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var t in new[] { frameTimer, deadlineTimer, rateTimer, gazeTimer, workTimer, hoverTimer, pulseTimer }) t.Stop();
        probeGeneration++;
    }
}
