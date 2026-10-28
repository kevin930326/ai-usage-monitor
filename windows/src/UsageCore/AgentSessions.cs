using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

// AI 的確切狀態（ADR-0017）：Claude Code 與 Codex 的 hook 把事件送到 App，這裡是三段共用邏輯——
// hook 從事件 JSON 只挑出幾個欄位（AgentHookInput）、App 驗證收到的一行（AgentHookMessage）、
// 每個工作階段的狀態與彙總（AgentSessions）。和 Mac 的 UsageKit/AgentSessions.swift 是同一份規則，
// 兩邊以 fixtures/agent 的 golden 比對；改規則時兩邊一起改。

/// <summary>哪個 AI</summary>
public enum AgentKind { Claude, Codex }

/// <summary>「需要你」與其他事件的種類（hook 從事件推得，只傳種類、不傳工具名稱或訊息）</summary>
public enum AgentNeed { Permission, Question, Plan, Idle }

/// <summary>hook 送出的事件（官方的 hook_event_name；白名單以外的名稱一律不送）</summary>
public enum AgentHookEvent
{
    SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
    Notification, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, Interrupt,
}

/// <summary>工作階段的狀態；彙總時取最高的（需要你 > 出錯 > 工作中 > 完成未看 > 等你 > 閒置）</summary>
public enum AgentState { Idle, Waiting, Done, Working, Error, NeedsYou }

public static class AgentNames
{
    /// <summary>AI 與種類用小寫（和 Swift 的 rawValue 相同）；事件用官方名稱</summary>
    public static string Name(AgentKind ai) => ai.ToString().ToLowerInvariant();
    public static string Name(AgentNeed need) => need.ToString().ToLowerInvariant();
    public static string Name(AgentHookEvent e) => e.ToString();
    public static string Name(AgentState state) => state switch
    {
        AgentState.NeedsYou => "needsYou",
        _ => state.ToString().ToLowerInvariant(),
    };

    public static AgentKind? Kind(string? name) => name switch { "claude" => AgentKind.Claude, "codex" => AgentKind.Codex, _ => null };

    public static AgentNeed? Need(string? name) => name switch
    {
        "permission" => AgentNeed.Permission,
        "question" => AgentNeed.Question,
        "plan" => AgentNeed.Plan,
        "idle" => AgentNeed.Idle,
        _ => null,
    };

    public static AgentHookEvent? Event(string? name) =>
        // TryParse 也接受數字字串（例如 "15"，未定義的值 ToString() 也是 "15"）：要求是定義過的名稱（Codex C-05）
        name is not null && Enum.TryParse<AgentHookEvent>(name, ignoreCase: false, out var e) && Enum.IsDefined(e)
            && e.ToString() == name ? e : null;

    /// <summary>安裝時要掛上的事件（各 AI 的官方文件有的才掛；2026-10-28 查閱）</summary>
    public static IReadOnlyList<AgentHookEvent> Installed(AgentKind ai) => ai switch
    {
        AgentKind.Claude =>
        [
            AgentHookEvent.SessionStart, AgentHookEvent.SessionEnd, AgentHookEvent.UserPromptSubmit, AgentHookEvent.PreToolUse,
            AgentHookEvent.PostToolUse, AgentHookEvent.PostToolUseFailure, AgentHookEvent.PermissionRequest,
            AgentHookEvent.Notification, AgentHookEvent.Stop, AgentHookEvent.StopFailure, AgentHookEvent.SubagentStop,
            AgentHookEvent.PreCompact,
        ],
        _ =>
        [
            AgentHookEvent.SessionStart, AgentHookEvent.SessionEnd, AgentHookEvent.UserPromptSubmit, AgentHookEvent.PreToolUse,
            AgentHookEvent.PostToolUse, AgentHookEvent.PermissionRequest, AgentHookEvent.Stop, AgentHookEvent.SubagentStop,
            AgentHookEvent.PreCompact, AgentHookEvent.Interrupt,
        ],
    };

    internal static string? Text(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;

    internal static JsonObject? Object(byte[] data)
    {
        try
        {
            if (JsonNode.Parse(data) is not JsonObject o) return null;
            // JsonObject 延到第一次讀取才檢查重複鍵（丟 ArgumentException）：在這裡就讀一次，格式不對只回 null、不當機
            _ = o.Count;
            return o;
        }
        catch (Exception e) when (e is JsonException or ArgumentException or InvalidOperationException) { return null; }
    }
}

/// <summary>
/// hook 從標準輸入的事件 JSON 取出的東西。其餘欄位（提示、工具輸入與輸出、訊息、紀錄路徑、完整的工作目錄）
/// 在這裡就丟掉，不會進到任何回傳值（隱私底線）。
/// </summary>
/// <remarks>Sub：事件來自子代理（輸入有 agent_id；只記有沒有，不記內容）</remarks>
public sealed record AgentHookInput(AgentHookEvent Event, AgentNeed? Need, string SessionId, string Folder, bool Sub = false)
{
    /// <summary>事件 JSON 最多讀多少（超過就整個丟掉）</summary>
    public const int MaxInput = 1 << 20;
    /// <summary>資料夾名稱最多幾個字（Unicode 純量）</summary>
    public const int MaxFolder = 48;

    /// <summary>解析事件；格式不對、事件不在白名單、或這個事件不影響狀態時回傳 null</summary>
    public static AgentHookInput? Extract(byte[] data)
    {
        if (data.Length > MaxInput) return null;
        var o = AgentNames.Object(data);
        if (o is null) return null;
        var e = AgentNames.Event(AgentNames.Text(o["hook_event_name"]));
        var sessionId = AgentNames.Text(o["session_id"]);
        if (e is null || string.IsNullOrEmpty(sessionId) || Encoding.UTF8.GetByteCount(sessionId) > 256) return null;
        AgentNeed? need = null;
        switch (e)
        {
            case AgentHookEvent.Notification:
                need = AgentNames.Text(o["notification_type"]) switch
                {
                    "permission_prompt" => AgentNeed.Permission,
                    "elicitation_dialog" or "elicitation_url_dialog" or "agent_needs_input" => AgentNeed.Question,
                    "idle_prompt" => AgentNeed.Idle,
                    _ => null,
                };
                if (need is null) return null;
                break;
            case AgentHookEvent.PermissionRequest:
                need = AgentNeed.Permission;
                break;
            case AgentHookEvent.PreToolUse:
                need = AgentNames.Text(o["tool_name"]) switch
                {
                    "AskUserQuestion" or "request_user_input" => AgentNeed.Question,
                    "ExitPlanMode" => AgentNeed.Plan,
                    _ => null,
                };
                break;
        }
        // 子代理的事件帶父工作階段的 session_id，另有 agent_id（Fable F-03）
        var sub = !string.IsNullOrEmpty(AgentNames.Text(o["agent_id"]));
        return new AgentHookInput(e.Value, need, sessionId, FolderName(AgentNames.Text(o["cwd"])), sub);
    }

    /// <summary>完整路徑只取最後一段；去掉控制與格式字元（同 Swift 的 controlCharacters），最多 48 個純量</summary>
    public static string FolderName(string? path)
    {
        if (path is null) return "";
        var parts = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "";
        var sb = new StringBuilder();
        var count = 0;
        foreach (var rune in parts[^1].EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.Format) continue;
            if (count++ == MaxFolder) break;
            sb.Append(rune.ToString());
        }
        return sb.ToString();
    }
}

/// <summary>
/// hook 經 socket 送給 App 的一行 JSON：
/// {"v":1,"ai":"claude","ev":"Stop","need":"","sub":false,"sid":"0123456789abcdef","t":1761650000000,"dir":"my-project"}
/// </summary>
public sealed record AgentHookMessage(AgentKind Ai, AgentHookEvent Event, AgentNeed? Need, string Session, long Time, string Folder,
                                      bool Sub = false)
{
    public const int Version = 1;
    /// <summary>一行最多多少位元組（App 讀超過就丟掉）</summary>
    public const int MaxLength = 1024;

    private static readonly string[] Keys = ["v", "ai", "ev", "need", "sub", "sid", "t", "dir"];

    /// <summary>送出的一行（不含換行）；鍵的順序固定，和 Swift 輸出相同</summary>
    public byte[] Encoded()
    {
        var text = $"{{\"v\":{Version},\"ai\":{Quote(AgentNames.Name(Ai))},\"ev\":{Quote(AgentNames.Name(Event))}," +
                   $"\"need\":{Quote(Need is { } n ? AgentNames.Name(n) : "")},\"sub\":{(Sub ? "true" : "false")}," +
                   $"\"sid\":{Quote(Session)}," +
                   $"\"t\":{Time.ToString(CultureInfo.InvariantCulture)},\"dir\":{Quote(Folder)}}}";
        return Encoding.UTF8.GetBytes(text);
    }

    /// <summary>
    /// 驗證收到的一行：版本、欄位、白名單、長度都要對，否則回傳 null（App 直接丟掉）。
    /// 最後要求重新編碼後和收到的一字不差：1.0、1e3、重複鍵、多餘空白都不收，和 Swift 一樣嚴格（Fable F-12）
    /// </summary>
    public static AgentHookMessage? Parse(byte[] data)
    {
        if (data.Length > MaxLength) return null;
        var o = AgentNames.Object(data);
        if (o is null || o.Count != Keys.Length || !Keys.All(o.ContainsKey)) return null;
        if (o["v"] is not JsonValue v || v.GetValueKind() != JsonValueKind.Number || !v.TryGetValue<int>(out var version)
            || version != Version) return null;
        var ai = AgentNames.Kind(AgentNames.Text(o["ai"]));
        var e = AgentNames.Event(AgentNames.Text(o["ev"]));
        var needText = AgentNames.Text(o["need"]);
        var session = AgentNames.Text(o["sid"]);
        var folder = AgentNames.Text(o["dir"]);
        if (ai is null || e is null || needText is null || session is null || !IsSessionHash(session) || folder is null) return null;
        if (o["t"] is not JsonValue t || t.GetValueKind() != JsonValueKind.Number || !t.TryGetValue<long>(out var time) || time <= 0)
            return null;
        if (folder.Length > 0 && folder != AgentHookInput.FolderName(folder)) return null;
        if (o["sub"] is not JsonValue subValue || subValue.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)) return null;
        var sub = subValue.GetValue<bool>();
        AgentNeed? need = null;
        if (needText.Length > 0)
        {
            need = AgentNames.Need(needText);
            if (need is null) return null;
        }
        var message = new AgentHookMessage(ai.Value, e.Value, need, session, time, folder, sub);
        return message.Encoded().AsSpan().SequenceEqual(data) ? message : null;
    }

    public static bool IsSessionHash(string text) =>
        text.Length == 16 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    internal static string Quote(string text)
    {
        var sb = new StringBuilder("\"");
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value == '"') sb.Append("\\\"");
            else if (rune.Value == '\\') sb.Append("\\\\");
            else if (rune.Value < 0x20) sb.Append("\\u").Append(rune.Value.ToString("x4", CultureInfo.InvariantCulture));
            else sb.Append(rune.ToString());
        }
        return sb.Append('"').ToString();
    }
}

/// <summary>一個工作階段。Stored 是存的狀態（閒置由「等你」加上時間算出，見 State）</summary>
/// <remarks>TurnStart：這一回合開始工作的時間（從不在跑的狀態進入工作中時記下；完成後用來算跑了多久）</remarks>
public sealed record AgentSession(AgentKind Ai, string Id, string Folder, AgentState Stored, AgentNeed? Need, long Since, long Last,
                                  long? TurnStart = null)
{
    public AgentState State(long now, long idleAfter) =>
        Stored == AgentState.Waiting && now - Since >= idleAfter ? AgentState.Idle : Stored;
}

public sealed class AgentSessions(long idleAfter)
{
    /// <summary>工作中超過這麼久沒有事件，當成被中斷了（Claude Code 被使用者中斷時不送 Stop）</summary>
    public const long WorkingTimeout = 20 * 60_000;
    /// <summary>需要你超過這麼久沒有事件，當成沒人等了（例如直接關掉終端機，沒送 SessionEnd；Fable F-06）</summary>
    public const long NeedsYouTimeout = 60 * 60_000;
    /// <summary>任何狀態超過這麼久沒有事件就移除（例如 AI 當掉、沒送 SessionEnd）</summary>
    public const long ForgetAfter = 12 * 3_600_000;
    /// <summary>同時最多記幾個工作階段（假事件塞爆時丟掉最久沒事件的）</summary>
    public const int MaxSessions = 32;

    private readonly List<AgentSession> sessions = [];
    /// <summary>每個工作階段（含已結束的）最後一個事件在 hook 端的時間：較晚讀完的舊事件丟掉（Codex C-02）</summary>
    private readonly Dictionary<string, long> latest = [];

    /// <summary>等你多久算閒置（設定的「睡覺」分鐘數）</summary>
    public long IdleAfter { get; set; } = idleAfter;
    public IReadOnlyList<AgentSession> Sessions => sessions;

    public bool Apply(AgentHookMessage message, long now)
    {
        var key = $"{AgentNames.Name(message.Ai)}/{message.Session}";
        if (latest.TryGetValue(key, out var seen) && message.Time < seen) return false;
        latest[key] = message.Time;
        if (latest.Count > MaxSessions * 2) latest.Remove(latest.MinBy(p => p.Value).Key);
        var index = sessions.FindIndex(s => s.Ai == message.Ai && s.Id == message.Session);
        if (message.Event == AgentHookEvent.SessionEnd)
        {
            if (index >= 0) sessions.RemoveAt(index);
            return true;
        }
        var session = index >= 0
            ? sessions[index]
            : new AgentSession(message.Ai, message.Session, message.Folder, AgentState.Waiting, null, now, now);
        if (message.Folder.Length > 0) session = session with { Folder = message.Folder };
        session = session with { Last = now };
        var next = Transition(session.Stored, message.Event, message.Need, message.Sub);
        if (next is { } n && (n.State != session.Stored || n.Need != session.Need))
        {
            var wasRunning = session.Stored is AgentState.Working or AgentState.NeedsYou;
            if (n.State == AgentState.Working && !wasRunning) session = session with { TurnStart = now };
            session = session with { Stored = n.State, Need = n.Need, Since = now };
        }
        if (index >= 0)
        {
            sessions[index] = session;
            return true;
        }
        sessions.Add(session);
        if (sessions.Count > MaxSessions)
        {
            var oldest = 0;
            for (var i = 1; i < sessions.Count; i++)
                if (sessions[i].Last < sessions[oldest].Last) oldest = i;
            sessions.RemoveAt(oldest);
        }
        return true;
    }

    /// <summary>
    /// 狀態轉換；null 表示不變。子代理的工具事件不把完成、等你、出錯改回工作中（Fable F-03）；
    /// 工作中收到 SessionStart（回合中途自動壓縮）時維持（Fable F-07）
    /// </summary>
    internal static (AgentState State, AgentNeed? Need)? Transition(AgentState state, AgentHookEvent e, AgentNeed? need,
                                                                    bool sub = false)
    {
        var stillRunning = state is AgentState.Working or AgentState.NeedsYou;
        (AgentState, AgentNeed?)? running = sub && !stillRunning ? null : (AgentState.Working, null);
        return e switch
        {
            AgentHookEvent.SessionStart => state == AgentState.Working ? null : (AgentState.Waiting, null),
            AgentHookEvent.Interrupt => (AgentState.Waiting, null),
            AgentHookEvent.UserPromptSubmit => (AgentState.Working, null),
            AgentHookEvent.PostToolUse or AgentHookEvent.PostToolUseFailure => running,
            AgentHookEvent.PreToolUse => need is { } n && n != AgentNeed.Idle ? (AgentState.NeedsYou, n) : running,
            AgentHookEvent.PermissionRequest => (AgentState.NeedsYou, AgentNeed.Permission),
            AgentHookEvent.Notification => need switch
            {
                AgentNeed.Permission or AgentNeed.Question or AgentNeed.Plan => (AgentState.NeedsYou, need),
                // 已經等你輸入一陣子：還記成工作中的（漏了 Stop）改成等你；完成未看、需要你維持
                AgentNeed.Idle => state == AgentState.Working ? (AgentState.Waiting, null) : null,
                _ => null,
            },
            AgentHookEvent.Stop => (AgentState.Done, null),
            AgentHookEvent.StopFailure => (AgentState.Error, null),
            // 子代理與壓縮只代表還在跑：工作中或剛批准（需要你）時算工作中，其他狀態不變
            AgentHookEvent.SubagentStart or AgentHookEvent.SubagentStop or AgentHookEvent.PreCompact or AgentHookEvent.PostCompact =>
                stillRunning ? (AgentState.Working, null) : null,
            _ => null,
        };
    }

    /// <summary>使用者看過了（展開或點角色）：完成未看與出錯都變成等你</summary>
    public void MarkSeen(long now)
    {
        for (var i = 0; i < sessions.Count; i++)
            if (sessions[i].Stored is AgentState.Done or AgentState.Error)
                sessions[i] = sessions[i] with { Stored = AgentState.Waiting, Need = null, Since = now };
    }

    /// <summary>時間經過：工作中或需要你太久沒事件變等你、太久沒事件的移除。回傳是否有改變</summary>
    public bool Expire(long now)
    {
        var changed = sessions.RemoveAll(s => now - s.Last >= ForgetAfter) > 0;
        for (var i = 0; i < sessions.Count; i++)
        {
            long? timeout = sessions[i].Stored switch
            {
                AgentState.Working => WorkingTimeout,
                AgentState.NeedsYou => NeedsYouTimeout,
                _ => null,
            };
            if (timeout is not { } limit || now - sessions[i].Last < limit) continue;
            sessions[i] = sessions[i] with { Stored = AgentState.Waiting, Need = null, Since = sessions[i].Last + limit };
            changed = true;
        }
        return changed;
    }

    /// <summary>依優先順序排好的工作階段（同等級取最近有事件的；再相同依 AI、ID）</summary>
    public List<AgentSession> Ordered(long now)
    {
        var list = sessions.ToList();
        list.Sort((a, b) =>
        {
            var ra = (int)a.State(now, IdleAfter);
            var rb = (int)b.State(now, IdleAfter);
            if (ra != rb) return rb.CompareTo(ra);
            if (a.Last != b.Last) return b.Last.CompareTo(a.Last);
            if (a.Ai != b.Ai) return string.CompareOrdinal(AgentNames.Name(a.Ai), AgentNames.Name(b.Ai));
            return string.CompareOrdinal(a.Id, b.Id);
        });
        return list;
    }

    public AgentSession? Top(long now) => Ordered(now).FirstOrDefault();

    public int Count(AgentState state, long now) => sessions.Count(s => s.State(now, IdleAfter) == state);

    public bool Has(AgentKind ai) => sessions.Any(s => s.Ai == ai);

    public AgentState? Top(AgentKind ai, long now) => Ordered(now).FirstOrDefault(s => s.Ai == ai)?.State(now, IdleAfter);

    /// <summary>
    /// 角色的工作中與睡覺：有 hook 工作階段的 AI 照 hook 的狀態，其他 AI 照紀錄檔的修改時間（fallback）。
    /// 只有「工作中」算工作；所有 AI 都閒置才睡覺。需要你算醒著；完成未看、出錯、等你進入後超過睡覺時間就可以睡
    /// （未看的標記保留；Fable F-06）。
    /// </summary>
    public (bool Working, bool Idle) Activity(long now, IReadOnlyDictionary<AgentKind, (bool Working, bool Active)> fallback)
    {
        bool working = false, active = false;
        foreach (var ai in Enum.GetValues<AgentKind>())
        {
            var mine = sessions.Where(s => s.Ai == ai).ToList();
            if (mine.Count > 0)
            {
                foreach (var s in mine)
                {
                    working |= s.Stored == AgentState.Working;
                    active |= s.Stored is AgentState.Working or AgentState.NeedsYou || now - s.Since < IdleAfter;
                }
            }
            else if (fallback.TryGetValue(ai, out var probe))
            {
                working |= probe.Working;
                active |= probe.Active;
            }
        }
        return (working, !working && !active);
    }
}

/// <summary>該發的系統通知。只有 AI、種類與工作階段，不含資料夾名稱：通知中心會把通知內容存到磁碟（隱私底線）</summary>
public sealed record AgentNotice(AgentKind Ai, AgentNoticeKind Kind, AgentNeed? Need, string Key);

public enum AgentNoticeKind { NeedsYou, Done }

/// <summary>NeedsYouAfter：需要你多久還沒處理才發（預設 20 秒）；LongTask：跑超過多久的任務完成時發（預設 3 分鐘）</summary>
public sealed record AgentNoticePolicy(long NeedsYouAfter = 20_000, long LongTask = 180_000);

public static class AgentNotices
{
    /// <summary>現在該發的通知（呼叫端用 Key 去掉已經發過的）</summary>
    public static List<AgentNotice> Due(AgentSessions sessions, long now, AgentNoticePolicy policy)
    {
        var list = new List<AgentNotice>();
        foreach (var s in sessions.Ordered(now))
        {
            var key = Key(s);
            if (s.Stored == AgentState.NeedsYou && now - s.Since >= policy.NeedsYouAfter)
                list.Add(new AgentNotice(s.Ai, AgentNoticeKind.NeedsYou, s.Need, key));
            else if (s.Stored == AgentState.Done && s.TurnStart is { } start && s.Since - start >= policy.LongTask)
                list.Add(new AgentNotice(s.Ai, AgentNoticeKind.Done, null, key));
        }
        return list;
    }

    /// <summary>工作階段＋狀態＋進入時間：同一段狀態只通知一次</summary>
    public static string Key(AgentSession s) =>
        $"{AgentNames.Name(s.Ai)}/{s.Id}/{AgentNames.Name(s.Stored)}@{s.Since.ToString(CultureInfo.InvariantCulture)}";

    /// <summary>目前還存在的狀態的 key（不在裡面的已發紀錄可以丟掉）</summary>
    public static HashSet<string> Keys(AgentSessions sessions, long now) => [.. sessions.Ordered(now).Select(Key)];

    /// <summary>下一次要檢查通知的時間（還沒到時間的需要你）；沒有就是 null。門檻是 long.MaxValue（關閉）時不會溢位</summary>
    public static long? NextCheck(AgentSessions sessions, long now, AgentNoticePolicy policy)
    {
        long? next = null;
        foreach (var s in sessions.Sessions)
            if (s.Stored == AgentState.NeedsYou && now - s.Since < policy.NeedsYouAfter && s.Since <= long.MaxValue - policy.NeedsYouAfter)
                next = Math.Min(next ?? long.MaxValue, s.Since + policy.NeedsYouAfter);
        return next;
    }
}
