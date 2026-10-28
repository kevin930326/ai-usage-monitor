using System.Globalization;

namespace AIUsageMonitor.Core;

/// <summary>
/// Windows 圓環上的 AI 狀態（ADR-0019 第 1 節）：只顯示要你注意的三種——需要你（琥珀色外框）、完成未看、出錯。
/// 工作中、等你、閒置不顯示。文字只有 AI 與種類（Windows 上不顯示資料夾名稱）。
/// </summary>
public sealed record RingAgent(AgentKind Ai, AgentState State, AgentNeed? Need)
{
    public static RingAgent? From(AgentSessions sessions, long now) =>
        sessions.Top(now) is { } top && top.State(now, sessions.IdleAfter) is AgentState.NeedsYou or AgentState.Done or AgentState.Error
            ? new RingAgent(top.Ai, top.State(now, sessions.IdleAfter), top.Stored == AgentState.NeedsYou ? top.Need : null)
            : null;

    public string Name => AgentText.Name(Ai);

    /// <summary>展開膠囊、提示與螢幕閱讀器的一句話</summary>
    public string Title => State switch
    {
        AgentState.NeedsYou => $"{Name} 需要你",
        AgentState.Done => $"{Name} 完成了",
        _ => $"{Name} 出錯了",
    };

    public string Detail => State switch
    {
        AgentState.NeedsYou => AgentText.NeedDetail(Need),
        AgentState.Done => "回去看看結果",
        _ => "回去看看發生了什麼",
    };
}

public static class AgentText
{
    public static string Name(AgentKind ai) => ai == AgentKind.Claude ? "Claude Code" : "Codex";

    /// <summary>同 Mac 的通知內容</summary>
    public static string NeedDetail(AgentNeed? need) => need switch
    {
        AgentNeed.Permission => "等你允許一個動作",
        AgentNeed.Question => "有問題等你回答",
        AgentNeed.Plan => "計畫等你確認",
        _ => "等你處理",
    };

    /// <summary>系統通知的標題與內容（只有 AI 與種類；通知會被系統存下來）</summary>
    public static (string Title, string Body) Notice(AgentNotice notice, int longTaskMinutes) => notice.Kind switch
    {
        AgentNoticeKind.NeedsYou => ($"{Name(notice.Ai)} 需要你", NeedDetail(notice.Need)),
        _ => ($"{Name(notice.Ai)} 完成了", $"跑了 {longTaskMinutes.ToString(CultureInfo.InvariantCulture)} 分鐘以上的任務完成了"),
    };
}

/// <summary>發過的通知（同 UsageKit 的 AgentNoticeLog）：只放記憶體，狀態結束或工作階段消失就清掉</summary>
public sealed class AgentNoticeLog
{
    private HashSet<string> sent = [];

    /// <summary>這次該送的（還沒送過的）；呼叫後都記成送過（不能送時也一樣，之後不補發）</summary>
    public List<AgentNotice> Take(AgentSessions sessions, long now, AgentNoticePolicy policy)
    {
        var fresh = AgentNotices.Due(sessions, now, policy).Where(n => !sent.Contains(n.Key)).ToList();
        var alive = AgentNotices.Keys(sessions, now);
        sent = [.. sent.Where(alive.Contains), .. fresh.Select(n => n.Key)];
        return fresh;
    }
}
