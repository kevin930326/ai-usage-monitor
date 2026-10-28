using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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
/// </summary>
internal sealed class AgentMonitor : IDisposable
{
    private readonly string home;
    private readonly AppSettings settings;
    private readonly DispatcherTimer next;
    private readonly HashSet<string> seen = [];
    private readonly AgentNoticeLog log = new();
    private bool started;
    private byte[]? lastState;
    private long lastStateWrite;
    private const long StateRewriteMs = 5 * 60_000;

    public AgentSessions Sessions { get; } = new(10 * 60_000);
    /// <summary>其他電腦要顯示的狀態（30 分鐘內），依狀態排序</summary>
    public IReadOnlyList<RemoteAgent> Remote { get; private set; } = [];
    /// <summary>狀態變了（圓環與系統匣重畫）</summary>
    public event Action? Changed;
    /// <summary>該發的通知（標題、內容）</summary>
    public event Action<string, string>? Notify;

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
    }

    /// <summary>hook 叫醒（具名事件）時</summary>
    public void Pump()
    {
        if (!started) return;
        var now = Now;
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now), now);
    }

    /// <summary>每分鐘：時間經過的狀態改變（工作中太久、需要你太久）、退路的掃描與其他電腦的狀態</summary>
    public void Tick()
    {
        if (!started) return;
        var now = Now;
        var remoteChanged = LoadRemote(now);
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now) || remoteChanged, now);
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

    /// <summary>使用者看過了（打開面板、點圓環）：完成未看與出錯變成等你</summary>
    public void MarkSeen()
    {
        var before = RingAgent.From(Sessions, Now);
        Sessions.MarkSeen(Now);
        if (before is { State: AgentState.Done or AgentState.Error })
        {
            WriteState(Now);
            Changed?.Invoke();
        }
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
    }

    public void Dispose()
    {
        next.Stop();
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
