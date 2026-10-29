using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 收 aum-hook.exe 的事件（ADR-0019 第 1 節）：hook 把一個事件寫成 <c>agent\inbox\</c> 的一個檔，再觸發具名事件叫醒 App。
/// 這裡等那個事件（不輪詢；AppHost 每分鐘的計時器也呼叫 <see cref="Tick"/> 作為退路）、依檔名排序處理、套用到 <see cref="AgentSessions"/>，
/// 並在需要你太久或長任務完成時以系統匣的通知提示（只寫 AI 與種類，沒有按鈕）。
/// 啟動時建立鹽與 inbox（有了 inbox，hook 才會寫）並處理留下的（只刪處理過的，不清空：啟動中途寫入的新事件不會被刪，Codex C-02）；
/// 結束時清空。
/// 跨裝置（第 2 節）：彙總寫到 agent-state.json（內容改變時寫並觸發 AgentSync 排程、每 5 分鐘重寫、結束時寫全部閒置），
/// 其他電腦的狀態每分鐘讀 agent-remote.json（收集器寫的）。
/// 背景工作（第 7 節）：主回合 Stop 後在背景執行緒列 AI 程序的子孫程序（只有 PID、父 PID、建立時間），只在有要看的工作階段時排計時器。
/// 切回宿主程式（第 8 節）：前景改變時比對執行檔名稱，完成之後才切過來、或完成後停留滿 3 秒的「完成未看」算看過。
/// </summary>
internal sealed class AgentMonitor : IDisposable
{
    private readonly string home;
    private readonly AppSettings settings;
    private readonly DispatcherTimer next;
    private readonly DispatcherTimer background;
    private readonly DispatcherTimer host;
    private readonly Dispatcher dispatcher;
    private readonly AgentHosts hosts = LoadHosts();
    private AgentForeground? foreground;
    private IReadOnlySet<AgentKind> foregroundAis = new HashSet<AgentKind>();
    private long foregroundSince;
    private bool probing;
    /// <summary>AI 程序的建立時間（PID 被重用時不會把別的程序當成 AI）</summary>
    private Dictionary<int, long> aiStarts = [];
    private readonly HashSet<string> seen = [];
    private readonly AgentNoticeLog log = new();
    private bool started;
    private byte[]? lastState;
    private long lastStateWrite;
    private const long StateRewriteMs = 5 * 60_000;

    public AgentSessions Sessions { get; } = new(AppSettings.DefaultSleepMinutes * 60_000L);
    /// <summary>其他電腦要顯示的狀態（30 分鐘內），依狀態排序</summary>
    public IReadOnlyList<RemoteAgent> Remote { get; private set; } = [];
    /// <summary>狀態變了（圓環與系統匣重畫）</summary>
    public event Action? Changed;
    /// <summary>該發的通知（標題、內容）</summary>
    public event Action<string, string>? Notify;
    /// <summary>有一個回合剛完成（角色揮手）</summary>
    public event Action? Finished;

    public AgentMonitor(Dispatcher dispatcher, string home, AppSettings settings)
    {
        this.home = home;
        this.settings = settings;
        next = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
        next.Tick += (_, _) =>
        {
            next.Stop();
            Tick();
        };
        this.dispatcher = dispatcher;
        background = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
        background.Tick += (_, _) =>
        {
            background.Stop();
            Probe();
        };
        host = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
        host.Tick += (_, _) =>
        {
            host.Stop();
            CheckHost();
        };
    }

    private static AgentHosts LoadHosts()
    {
        using var stream = typeof(AgentMonitor).Assembly.GetManifestResourceStream("agent-hosts.json");
        return stream is null ? AgentHosts.None : AgentHosts.Decode(new StreamReader(stream).ReadToEnd());
    }

    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public void Start()
    {
        try
        {
            AgentInbox.EnsureSalt(home);
            Directory.CreateDirectory(AgentInbox.InboxDirectory(home));
            started = true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // 建不了資料夾：hook 看不到 inbox 就不寫，App 照常
            AppLog.Write($"agent inbox: {e.GetType().Name}");
            return;
        }
        // App 沒在跑的時候 hook 不寫；留下的是上次沒處理完的（當機）：照事件時間套用，太舊的由 Expire 淘汰
        Tick();
        WriteState(Now);
        foreground = new AgentForeground(SetForeground);
        SetForeground(AgentForeground.Current());
    }

    private void SetForeground(string exe)
    {
        foregroundAis = hosts.Ais(exe.Length == 0 ? null : exe);
        foregroundSince = Now;
        CheckHost();
    }

    /// <summary>宿主程式在前景：完成之後才切過來的、或完成後停留滿 3 秒的「完成未看」標成已看；需要你與出錯不動</summary>
    private void CheckHost()
    {
        host.Stop();
        if (foregroundAis.Count == 0) return;
        var now = Now;
        if (Sessions.MarkSeenByHost(foregroundAis, foregroundSince, now))
        {
            WriteState(now);
            Changed?.Invoke();
        }
        if (Sessions.NextHostCheck(foregroundAis, foregroundSince, now) is not { } at) return;
        host.Interval = TimeSpan.FromMilliseconds(Math.Max(at - now, 50));
        host.Start();
    }

    /// <summary>有要拍基準或到時間要看的工作階段就去列程序；否則排到下一次要看的時間（沒有就不排）</summary>
    private void ScheduleBackground()
    {
        var now = Now;
        if (Sessions.BaselineRequests().Count > 0 || Sessions.BackgroundChecks(now).Count > 0)
        {
            Probe();
            return;
        }
        background.Stop();
        if (Sessions.NextBackgroundCheck is not { } at) return;
        background.Interval = TimeSpan.FromMilliseconds(Math.Clamp(at - now, 50, 3_600_000));
        background.Start();
    }

    /// <summary>在背景執行緒列 AI 程序的子孫程序，回到 UI 執行緒套用</summary>
    private void Probe()
    {
        if (probing) return;
        var baselines = Sessions.BaselineRequests();
        var checks = Sessions.BackgroundChecks(Now);
        if (baselines.Count == 0 && checks.Count == 0)
        {
            ScheduleBackground();
            return;
        }
        probing = true;
        var starts = new Dictionary<int, long>(aiStarts);
        Task.Run(() =>
        {
            var taken = baselines.Select(r => (r, AgentProcessTree.Start(r.Pid), AgentProcessTree.Descendants(r.Pid))).ToList();
            var seen = checks.Select(c => (c, AgentProcessTree.Descendants(c.Pid, starts.TryGetValue(c.Pid, out var s) ? s : null))).ToList();
            dispatcher.InvokeAsync(() =>
            {
                probing = false;
                foreach (var (r, start, processes) in taken)
                {
                    if (start is { } t) aiStarts[r.Pid] = t;
                    Sessions.SetBaseline(r.Ai, r.Id, r.Pid, r.Probe, processes);
                }
                var now = Now;
                var different = false;
                foreach (var (c, processes) in seen) different |= Sessions.Observe(c.Ai, c.Id, c.Pid, c.Probe, processes, now);
                // 已經沒有工作階段用的 AI 程序不必再記
                var live = Sessions.Ordered(now).Select(s => s.Pid).ToHashSet();
                aiStarts = aiStarts.Where(kv => live.Contains(kv.Key)).ToDictionary();
                if (different) Evaluate(true, now);
                else ScheduleBackground();
            });
        });
    }

    /// <summary>hook 叫醒（具名事件）時</summary>
    public void Pump()
    {
        if (!started) return;
        var now = Now;
        var done = Done(now);
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now), now);
        if (Done(now).Except(done).Any())
        {
            Finished?.Invoke();
            CheckHost();
        }
    }

    /// <summary>目前「完成」的工作階段（剛變成完成的就是剛完成一個回合）</summary>
    private HashSet<(AgentKind, string)> Done(long now) =>
        Sessions.Ordered(now).Where(s => s.Stored == AgentState.Done).Select(s => (s.Ai, s.Id)).ToHashSet();

    /// <summary>每分鐘：時間經過的狀態改變（工作中太久、需要你太久）、退路的掃描與其他電腦的狀態</summary>
    public void Tick()
    {
        if (!started) return;
        var now = Now;
        var remoteChanged = LoadRemote(now);
        var done = Done(now);
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now) || remoteChanged, now);
        if (Done(now).Except(done).Any()) Finished?.Invoke();
        if (now - lastStateWrite >= StateRewriteMs) WriteState(now, rewrite: true);
    }

    private bool LoadRemote(long now)
    {
        byte[] data;
        try
        {
            var path = Path.Combine(home, RemoteAgents.FileName);
            data = File.Exists(path) && new FileInfo(path).Length <= 64 * 1024 ? File.ReadAllBytes(path) : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            data = [];
        }
        List<RemoteAgent> loaded = data.Length == 0 ? [] : RemoteAgents.Parse(data, now);
        if (Enumerable.SequenceEqual(loaded, Remote)) return false;
        Remote = loaded;
        return true;
    }

    /// <summary>這台的彙總：內容改變時寫並觸發同步；rewrite 時內容一樣也重寫（收集器把 10 分鐘沒更新的當成 App 沒在跑）</summary>
    private void WriteState(long now, bool rewrite = false)
    {
        var data = AgentSummary.Encoded(Sessions, now);
        var changed = lastState is null || !data.AsSpan().SequenceEqual(lastState);
        if (!changed && !rewrite) return;
        if (!TryWriteState(data)) return;
        lastState = data;
        lastStateWrite = now;
        if (changed) AgentSyncTrigger.Run();
    }

    private bool TryWriteState(byte[] data)
    {
        var path = Path.Combine(home, AgentSummary.FileName);
        var temp = path + ".tmp";
        try
        {
            File.WriteAllBytes(temp, data);
            File.Move(temp, path, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"agent state: {e.GetType().Name}");
            return false;
        }
    }

    /// <summary>
    /// 使用者看過了（打開面板、點圓環）：完成未看與出錯變成等你。只要有任何工作階段改變就寫 agent-state.json 並重畫：
    /// 之前只在彙總是完成或出錯時才寫，同時有別的工作階段在工作中或需要你時，看過的不會同步出去（ADR-0017 第 9 節）
    /// </summary>
    public void MarkSeen()
    {
        if (!Sessions.MarkSeen(Now)) return;
        WriteState(Now);
        Changed?.Invoke();
    }

    /// <summary>通知設定改了：重新排下一次檢查</summary>
    public void SettingsChanged() => Evaluate(false, Now);

    private void Evaluate(bool changed, long now)
    {
        var policy = settings.AgentNoticePolicy;
        foreach (var notice in log.Take(Sessions, now, policy))
        {
            var (title, body) = AgentText.Notice(notice, settings.AgentLongTaskMinutes);
            Notify?.Invoke(title, body);
            AppLog.Write($"notified agent {notice.Kind} {AgentNames.Name(notice.Ai)}");
        }
        next.Stop();
        if (AgentNotices.NextCheck(Sessions, now, policy) is { } at)
        {
            next.Interval = TimeSpan.FromMilliseconds(Math.Clamp(at - now + 50, 50, 3_600_000));
            next.Start();
        }
        if (changed)
        {
            WriteState(now);
            Changed?.Invoke();
        }
        ScheduleBackground();
    }

    public void Dispose()
    {
        next.Stop();
        background.Stop();
        host.Stop();
        foreground?.Dispose();
        if (!started) return;
        AgentInbox.Clear(home);
        // 其他電腦馬上看到這台沒事，而不是等 30 分鐘過期。
        // 還有沒送出的合併觸發時也要送（最後一個工作階段剛結束就關 App：檔案已是全部閒置，Codex C-01）
        var pending = AgentSyncTrigger.TakePending();
        var wroteIdle = lastState is not null && !lastState.AsSpan().SequenceEqual(AgentSummary.Empty) && TryWriteState(AgentSummary.Empty);
        if (wroteIdle || pending)
        {
            AgentSyncTrigger.RunAndForget();
        }
    }
}
