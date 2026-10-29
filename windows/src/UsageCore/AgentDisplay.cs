using System.Globalization;

namespace AIUsageMonitor.Core;

/// <summary>
/// Windows 圓環上的 AI 狀態（ADR-0019 第 1 節）：只顯示要你注意的三種——需要你（琥珀色外框）、完成未看、出錯。
/// 工作中、背景執行中、等你、閒置不顯示。文字只有 AI 與種類（Windows 上不顯示資料夾名稱）。
/// 這台沒有要注意的時，其他電腦「需要你」也顯示（第 2 節；<see cref="Device"/> 是那台的名稱）。
/// 其他電腦的完成與出錯不上圓環：這裡看過也消不掉，只能回那台處理。
/// </summary>
public sealed record RingAgent(AgentKind Ai, AgentState State, AgentNeed? Need, string? Device = null)
{
    /// <summary>這台的工作階段（鹽雜湊）：點膠囊那一列跳回去用（ADR-0017 第 10 節）；其他電腦的是 null</summary>
    public string? Session { get; init; }
    /// <summary>點了跳不過去時暫時取代第二行的文字（「找不到這個工作階段的視窗」「在桌機上」，2 秒）</summary>
    public string? Hint { get; init; }

    /// <summary>
    /// merged（角色樣式，ADR-0019「角色合併所有電腦」，Fable G-13）：膠囊第二行和角色講同一件事：任何一台需要你 > 出錯（其他電腦的出錯
    /// 在這台看過就不算，seenErrors）> 這台的完成。圓環樣式（C2）維持原本：這台沒有要注意的時才顯示其他電腦的需要你
    /// </summary>
    public static RingAgent? From(AgentSessions sessions, long now, IReadOnlyList<RemoteAgent>? remote = null, bool merged = false,
                                  IReadOnlySet<string>? seenErrors = null)
    {
        // 背景執行中排在完成未看前面但不上圓環：跳過它，別的工作階段的完成未看照樣顯示（ADR-0017 第 7 節）
        var local = sessions.Ordered(now).FirstOrDefault(s => s.State(now, sessions.IdleAfter) is AgentState.NeedsYou or AgentState.Done or AgentState.Error);
        var localState = local?.State(now, sessions.IdleAfter);
        // 角色樣式：其他電腦的需要你和角色一樣只在中繼收到後 20 分鐘內算（AgentActivity.RemoteEffect，Codex C-02）
        bool Needs(RemoteAgent r) => r.State == AgentState.NeedsYou && (!merged || now - r.Updated <= AgentActivity.RemoteEffect);
        if (merged && localState != AgentState.NeedsYou)
        {
            if (remote?.FirstOrDefault(Needs) is { } needs) return new RingAgent(needs.Ai, AgentState.NeedsYou, null, needs.Device);
            if (localState != AgentState.Error
                && remote?.FirstOrDefault(r => r.State == AgentState.Error && seenErrors?.Contains(AgentActivity.ErrorKey(r)) != true) is { } error)
            {
                return new RingAgent(error.Ai, AgentState.Error, null, error.Device);
            }
        }
        if (local is { } top)
        {
            return new RingAgent(top.Ai, localState!.Value, top.Stored == AgentState.NeedsYou ? top.Need : null) { Session = top.Id };
        }
        return remote?.FirstOrDefault(Needs) is { } other
            ? new RingAgent(other.Ai, AgentState.NeedsYou, null, other.Device)
            : null;
    }

    public string Name => AgentText.Name(Ai);

    /// <summary>展開膠囊、提示與螢幕閱讀器的一句話；其他電腦的前面加名稱（「工作 PC：Codex 需要你」）</summary>
    public string Title => (Device is null ? "" : $"{Device}：") + State switch
    {
        AgentState.NeedsYou => $"{Name} 需要你",
        AgentState.Done => $"{Name} 完成了",
        _ => $"{Name} 出錯了",
    };

    public string Detail => Hint ?? (Device is not null ? "在另一台電腦" : State switch
    {
        AgentState.NeedsYou => AgentText.NeedDetail(Need),
        AgentState.Done => "回去看看結果",
        _ => "回去看看發生了什麼",
    });
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
