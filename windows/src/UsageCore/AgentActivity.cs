namespace AIUsageMonitor.Core;

/// <summary>
/// 角色合併所有電腦的狀態（ADR-0019「角色合併所有電腦」，同 Swift 的 AgentActivity）：本機的工作階段＋其他電腦（agent-remote.json）中
/// 最重要的狀態，換成狀態機要的旗標。由 fixtures/agent 的 activity golden 檢查。清單、通知與系統匣不用這裡
/// </summary>
/// <param name="Working">本機在工作（敲鍵盤＋思考泡泡）</param>
/// <param name="Background">本機背景執行中</param>
/// <param name="NeedsYou">任何一台需要你</param>
/// <param name="RemoteWorking">任何一台其他電腦在工作（含那台的背景執行中）</param>
/// <param name="RemoteError">其他電腦出錯（沒被這台看過壓下）</param>
/// <param name="Idle">所有電腦都閒置：才睡</param>
public sealed record AgentActivity(bool Working, bool Background, bool NeedsYou, bool RemoteWorking, bool RemoteError, bool Idle)
{
    /// <summary>其他電腦的工作中、需要你對角色的效力：中繼收到後 20 分鐘（Fable G-07）</summary>
    public const long RemoteEffect = 20 * 60_000;

    /// <summary>
    /// 遠端出錯在這台看過的記號（裝置名稱、AI、進入出錯的時間）：since 改了才再顯示（Fable G-06）。只在記憶體。
    /// 用中繼時鐘的原始 since：換算成本機的會隨每次下載的時間差變，重新下載後又會難過（Codex C-01）
    /// </summary>
    public static string ErrorKey(RemoteAgent agent) =>
        $"{agent.Device}|{AgentNames.Name(agent.Ai)}|{(agent.RelaySince is { } s ? s.ToString(System.Globalization.CultureInfo.InvariantCulture) : "-")}";

    /// <summary>
    /// remote 是 <c>RemoteAgents.Parse(_, _, all: true)</c> 的結果（含等你、閒置）；idleAfter 是本機的睡覺分鐘數（ms）。
    /// 遠端的需要你、出錯、工作中一律醒著（工作中、需要你在中繼收到後 20 分鐘內）；完成、等你從 since 起未超過睡覺分鐘數算醒著；閒置不算
    /// </summary>
    public static AgentActivity Combine(bool localWorking, bool localIdle, bool localNeedsYou, bool localBackground,
                                        IEnumerable<RemoteAgent> remote, long now, long idleAfter, IReadOnlySet<string>? seenErrors = null)
    {
        bool needsYou = localNeedsYou, remoteWorking = false, remoteError = false, remoteAwake = false;
        foreach (var agent in remote.Where(a => Shown(a, now)))
        {
            var fresh = now - agent.Updated <= RemoteEffect;
            switch (agent.State)
            {
                case AgentState.NeedsYou:
                    if (fresh) needsYou = remoteAwake = true;
                    break;
                case AgentState.Working or AgentState.Background:
                    if (fresh) remoteWorking = remoteAwake = true;
                    break;
                case AgentState.Error:
                    if (seenErrors?.Contains(ErrorKey(agent)) != true) remoteError = true;
                    remoteAwake = true;
                    break;
                case AgentState.Done or AgentState.Waiting:
                    if (agent.Since is { } since && now - since < idleAfter) remoteAwake = true;
                    break;
            }
        }
        return new AgentActivity(localWorking, localBackground, needsYou, remoteWorking, remoteError, localIdle && !remoteAwake);
    }

    /// <summary>只有其他電腦在工作（同狀態機的 ThinksRemotely）：動畫「簡單」「關閉」時狀態機不換姿勢，小電腦照這個靜態顯示（Fable G-11）</summary>
    public bool ThinksRemotely => RemoteWorking && !Working && !Background && !NeedsYou;

    /// <summary>表情用的狀態：需要你 > 出錯（本機或遠端）> 本機最重要的狀態。遠端的完成不讓角色開心</summary>
    public AgentState? MoodState(AgentState? localTop) =>
        NeedsYou ? AgentState.NeedsYou : localTop == AgentState.Error || RemoteError ? AgentState.Error : localTop;

    /// <summary>中繼收到後 30 分鐘內；完成、出錯從進入的時間起 30 分鐘內（同 RemoteAgents.Parse）</summary>
    private static bool Shown(RemoteAgent agent, long now)
    {
        if (now - agent.Updated > RemoteAgents.MaxAge) return false;
        return !(agent.State is AgentState.Done or AgentState.Error && agent.Since is { } since && now - since >= RemoteAgents.FadeAfter);
    }
}
