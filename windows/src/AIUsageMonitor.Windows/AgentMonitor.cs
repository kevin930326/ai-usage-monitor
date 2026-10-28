using System;
using System.Collections.Generic;
using System.IO;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 收 aum-hook.exe 的事件（ADR-0019 第 1 節）：hook 把一個事件寫成 <c>agent\inbox\</c> 的一個檔，再觸發具名事件叫醒 App。
/// 這裡等那個事件（不輪詢；AppHost 每分鐘的計時器也呼叫 <see cref="Tick"/> 作為退路）、依檔名排序處理、套用到 <see cref="AgentSessions"/>，
/// 並在需要你太久或長任務完成時以系統匣的通知提示（只寫 AI 與種類，沒有按鈕）。
/// 啟動時建立鹽與 inbox（有了 inbox，hook 才會寫）並處理留下的（只刪處理過的，不清空：啟動中途寫入的新事件不會被刪，Codex C-02）；
/// 結束時清空。
/// </summary>
internal sealed class AgentMonitor : IDisposable
{
    private readonly string home;
    private readonly AppSettings settings;
    private readonly DispatcherTimer next;
    private readonly HashSet<string> seen = [];
    private readonly AgentNoticeLog log = new();
    private bool started;

    public AgentSessions Sessions { get; } = new(10 * 60_000);
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
    }

    /// <summary>hook 叫醒（具名事件）時</summary>
    public void Pump()
    {
        if (!started) return;
        var now = Now;
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now), now);
    }

    /// <summary>每分鐘：時間經過的狀態改變（工作中太久、需要你太久）與退路的掃描</summary>
    public void Tick()
    {
        if (!started) return;
        var now = Now;
        Evaluate(AgentInbox.Apply(Sessions, AgentInbox.Drain(home, seen), now), now);
    }

    /// <summary>使用者看過了（打開面板、點圓環）：完成未看與出錯變成等你</summary>
    public void MarkSeen()
    {
        var before = RingAgent.From(Sessions, Now);
        Sessions.MarkSeen(Now);
        if (before is { State: AgentState.Done or AgentState.Error }) Changed?.Invoke();
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
        if (changed) Changed?.Invoke();
    }

    public void Dispose()
    {
        next.Stop();
        if (started) AgentInbox.Clear(home);
    }
}
