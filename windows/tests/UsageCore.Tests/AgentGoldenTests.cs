using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// AI 狀態的跨平台一致性（ADR-0017）：讀 fixtures/agent/cases.json，用 UsageCore 的 AgentHookInput、AgentHookMessage、
/// AgentSessions 算出結果，和 Swift（apple/UsageKit/Tests/UsageKitTests/AgentGoldenTests.swift）產生的 golden.json 比對。
/// </summary>
public class AgentGoldenTests
{
    private static string Agent(string name) => Path.Combine(LogicGoldenTests.RepoRoot, "fixtures", "agent", name);

    private static JsonNode Cases() => JsonNode.Parse(File.ReadAllText(Agent("cases.json")))!;

    private static string[] Extract(string raw)
    {
        var input = AgentHookInput.Extract(Encoding.UTF8.GetBytes(raw));
        return input is null
            ? ["nil"]
            : [$"event={AgentNames.Name(input.Event)}", $"need={(input.Need is { } n ? AgentNames.Name(n) : "")}",
               $"session={input.SessionId}", $"folder={input.Folder}", .. (input.Sub ? new[] { "sub" } : [])];
    }

    private static string[] Parse(string raw)
    {
        var message = AgentHookMessage.Parse(Encoding.UTF8.GetBytes(raw));
        return message is null ? ["nil"] : [Encoding.UTF8.GetString(message.Encoded())];
    }

    private static string Describe(AgentSessions sessions, long now)
    {
        var list = sessions.Ordered(now).Select(s =>
            $"{AgentNames.Name(s.Ai)}/{s.Id[..4]}/{s.Folder}:{AgentNames.Name(s.State(now, sessions.IdleAfter))}" +
            $"{(s.Need is { } n ? $"({AgentNames.Name(n)})" : "")}@{s.Since}" +
            (s.CheckAt is { } at ? $" check@{at.ToString(CultureInfo.InvariantCulture)}" : ""));
        var top = sessions.Top(now) is { } t ? $"{AgentNames.Name(t.Ai)}/{t.Id[..4]}" : "none";
        return $"top={top} [{string.Join(", ", list)}]";
    }

    private static string[] Run(JsonNode testCase)
    {
        var sessions = new AgentSessions(testCase["idle_after_ms"]?.GetValue<long>() ?? 300_000);
        var log = new List<string>();
        // hold：記下現在要拍的基準與要看的工作階段（非同步列程序的途中）；late：途中又有事件之後，才把那時的結果交回來（Codex C-01）
        List<(AgentKind Ai, string Id, int Pid, long Probe)> heldBaselines = [], heldChecks = [];
        foreach (var e in testCase["events"]!.AsArray())
        {
            var t = e!["t"]!.GetValue<long>();
            switch (e["e"]!.GetValue<string>())
            {
                case "hold":
                    heldBaselines = sessions.BaselineRequests();
                    heldChecks = sessions.BackgroundChecks(t);
                    log.Add($"{t} hold baselines={heldBaselines.Count} checks={heldChecks.Count}");
                    break;
                case "late":
                    foreach (var r in heldBaselines) sessions.SetBaseline(r.Ai, r.Id, r.Pid, r.Probe, Processes(e["procs"]));
                    foreach (var c in heldChecks) sessions.Observe(c.Ai, c.Id, c.Pid, c.Probe, Processes(e["procs"]), t);
                    heldBaselines = [];
                    heldChecks = [];
                    var lateNext = sessions.NextBackgroundCheck;
                    log.Add($"{t} late → {Describe(sessions, t)} next={(lateNext is { } ln ? ln.ToString(CultureInfo.InvariantCulture) : "none")}");
                    break;
                case "msg":
                    var ai = e["ai"]!.GetValue<string>();
                    var ev = e["ev"]!.GetValue<string>();
                    var need = e["need"]?.GetValue<string>() ?? "";
                    var sub = e["sub"]?.GetValue<bool>() ?? false;
                    var sent = e["sent"]?.GetValue<long>() ?? t;
                    var applied = sessions.Apply(new AgentHookMessage(AgentNames.Kind(ai)!.Value, AgentNames.Event(ev)!.Value, AgentNames.Need(need),
                                                                      e["sid"]!.GetValue<string>(), sent, e["dir"]?.GetValue<string>() ?? "", sub,
                                                                      e["pid"]?.GetValue<int>() ?? 0), t);
                    var wants = sessions.BaselineRequests().Select(r => $"{AgentNames.Name(r.Ai)}/{r.Id[..4]}").ToList();
                    log.Add($"{t} {ai} {ev}{(need.Length > 0 ? $"({need})" : "")}{(sub ? "[sub]" : "")}{(applied ? "" : " (stale)")} → {Describe(sessions, t)}" +
                            (wants.Count > 0 ? $" baseline? {string.Join(",", wants)}" : ""));
                    break;
                case "baseline":
                    foreach (var r in sessions.BaselineRequests()) sessions.SetBaseline(r.Ai, r.Id, r.Pid, r.Probe, Processes(e["procs"]));
                    log.Add($"{t} baseline → {Describe(sessions, t)}");
                    break;
                case "procs":
                    var due = sessions.BackgroundChecks(t);
                    foreach (var c in due) sessions.Observe(c.Ai, c.Id, c.Pid, c.Probe, Processes(e["procs"]), t);
                    var nextCheck = sessions.NextBackgroundCheck;
                    log.Add($"{t} procs checked={due.Count} → {Describe(sessions, t)} next={(nextCheck is { } nc ? nc.ToString(CultureInfo.InvariantCulture) : "none")}");
                    break;
                case "fg":
                    var names = e["ais"]!.AsArray().Select(a => a!.GetValue<string>()).ToList();
                    var ais = names.Select(AgentNames.Kind).OfType<AgentKind>().ToHashSet();
                    var fgSince = e["since"]?.GetValue<long>() ?? t;
                    var seenByHost = sessions.MarkSeenByHost(ais, fgSince, t);
                    var hostNext = sessions.NextHostCheck(ais, fgSince, t);
                    log.Add($"{t} fg {string.Join("+", names)}{(seenByHost ? "" : " (no change)")} → {Describe(sessions, t)} " +
                            $"next={(hostNext is { } hn ? hn.ToString(CultureInfo.InvariantCulture) : "none")}");
                    break;
                case "activity":
                    var (working, idle) = sessions.Activity(t, new Dictionary<AgentKind, (bool, bool)>());
                    log.Add($"{t} activity working={(working ? "true" : "false")} idle={(idle ? "true" : "false")}");
                    break;
                case "notices":
                    var policy = new AgentNoticePolicy();
                    var notices = AgentNotices.Due(sessions, t, policy).Select(n =>
                        $"{AgentNames.Name(n.Ai)}:{(n.Kind == AgentNoticeKind.NeedsYou ? "needsYou" : "done")}" +
                        $"{(n.Need is { } nd ? $"({AgentNames.Name(nd)})" : "")} key={n.Key}");
                    var next = AgentNotices.NextCheck(sessions, t, policy);
                    log.Add($"{t} notices [{string.Join(", ", notices)}] next={(next is { } nx ? nx.ToString(CultureInfo.InvariantCulture) : "none")}");
                    break;
                case "summary":
                    log.Add($"{t} summary {Encoding.UTF8.GetString(AgentSummary.Encoded(sessions, t))}");
                    break;
                case "seen":
                    sessions.MarkSeen(t);
                    log.Add($"{t} seen → {Describe(sessions, t)}");
                    break;
                case "expire":
                    var changed = sessions.Expire(t);
                    log.Add($"{t} expire{(changed ? "" : " (no change)")} → {Describe(sessions, t)}");
                    break;
                default:
                    throw new InvalidOperationException($"不認得的事件 {e["e"]}");
            }
        }
        return [.. log];
    }

    private static List<AgentProcess>? Processes(JsonNode? list) =>
        list is JsonArray array ? [.. array.Select(p => new AgentProcess(p![0]!.GetValue<int>(), p[1]!.GetValue<long>()))] : null;

    private static void Compare(string section, Func<JsonNode, string[]> run)
    {
        var cases = Cases()[section]!.AsArray();
        var golden = JsonNode.Parse(File.ReadAllText(Agent("golden.json")))![section]!.AsArray();
        Assert.Equal(cases.Count, golden.Count);
        for (var i = 0; i < cases.Count; i++)
        {
            var expected = golden[i]!["result"]!.AsArray().Select(x => x!.GetValue<string>()).ToArray();
            Assert.Equal(golden[i]!["name"]!.GetValue<string>(), cases[i]!["name"]!.GetValue<string>());
            Assert.Equal(expected, run(cases[i]!));
        }
    }

    [Fact] public void InputsMatchGolden() => Compare("inputs", c => Extract(c["raw"]!.GetValue<string>()));

    [Fact] public void MessagesMatchGolden() => Compare("messages", c => Parse(c["raw"]!.GetValue<string>()));

    [Fact] public void SessionsMatchGolden() => Compare("sessions", Run);

    [Fact]
    public void RemoteMatchesGolden() => Compare("remote", c =>
        [.. RemoteAgents.Parse(Encoding.UTF8.GetBytes(c["raw"]!.GetValue<string>()), c["local_now"]!.GetValue<long>())
            .Select(r => $"{r.Device}|{AgentNames.Name(r.Ai)}|{AgentNames.Name(r.State)}|{r.Sessions}|{r.Text}")]);

    /// <summary>切回 AI 的程式（ADR-0017 第 8 節）：shared/agent-hosts.json 能讀、不分大小寫、終端機代表兩個 AI</summary>
    [Fact]
    public void HostsReadTheSharedList()
    {
        var hosts = AgentHosts.Decode(File.ReadAllText(Path.Combine(LogicGoldenTests.RepoRoot, "shared", "agent-hosts.json")));
        Assert.Equal([AgentKind.Claude], hosts.Ais("Claude.exe").Order());
        Assert.Equal([AgentKind.Codex], hosts.Ais("codex.exe").Order());
        Assert.Equal([AgentKind.Claude, AgentKind.Codex], hosts.Ais("WindowsTerminal.exe").Order());
        Assert.Equal([AgentKind.Claude, AgentKind.Codex], hosts.Ais("POWERSHELL.EXE").Order());
        Assert.Empty(hosts.Ais("msedge.exe"));
        Assert.Empty(hosts.Ais(null));
        Assert.Empty(AgentHosts.Decode("{").Ais("cmd.exe"));
    }

    [Fact]
    public void EncodedMessageRoundTrips()
    {
        var message = new AgentHookMessage(AgentKind.Codex, AgentHookEvent.PostToolUseFailure, AgentNeed.Permission, "0123456789abcdef",
                                           long.MaxValue, new string('名', AgentHookInput.MaxFolder));
        var data = message.Encoded();
        Assert.True(data.Length <= AgentHookMessage.MaxLength);
        Assert.Equal(message, AgentHookMessage.Parse(data));
    }

    /// <summary>通知關閉（門檻 long.MaxValue）：不發、也不排下一次檢查，不會溢位</summary>
    [Fact]
    public void DisabledNoticesNeverFire()
    {
        var sessions = new AgentSessions(300_000);
        var off = new AgentNoticePolicy(long.MaxValue, long.MaxValue);
        sessions.Apply(new AgentHookMessage(AgentKind.Claude, AgentHookEvent.UserPromptSubmit, null, "0123456789abcdef", 0, ""), 0);
        sessions.Apply(new AgentHookMessage(AgentKind.Claude, AgentHookEvent.PermissionRequest, AgentNeed.Permission, "0123456789abcdef",
                                            1000, ""), 1_000_000);
        Assert.Empty(AgentNotices.Due(sessions, 9_000_000, off));
        Assert.Null(AgentNotices.NextCheck(sessions, 9_000_000, off));
    }

    [Fact]
    public void ActivityPrefersHookAndFallsBackPerAgent()
    {
        var quiet = new Dictionary<AgentKind, (bool, bool)> { [AgentKind.Claude] = (false, false), [AgentKind.Codex] = (false, false) };
        var sessions = new AgentSessions(300_000);
        Assert.Equal((false, true), sessions.Activity(0, quiet));
        Assert.Equal((true, false), sessions.Activity(0, new Dictionary<AgentKind, (bool, bool)> { [AgentKind.Codex] = (true, true) }));
        AgentHookMessage M(AgentHookEvent e) => new(AgentKind.Claude, e, null, "0123456789abcdef", 1, "");
        sessions.Apply(M(AgentHookEvent.UserPromptSubmit), 0);
        Assert.Equal((true, false), sessions.Activity(1000, quiet));
        sessions.Apply(M(AgentHookEvent.Stop), 2000);
        Assert.Equal((false, false), sessions.Activity(3000, quiet));
        sessions.MarkSeen(4000);
        Assert.Equal((false, true), sessions.Activity(4000 + 300_000, quiet));
        Assert.Equal((false, false), sessions.Activity(4000 + 300_000,
            new Dictionary<AgentKind, (bool, bool)> { [AgentKind.Claude] = (true, true), [AgentKind.Codex] = (false, true) }));
    }

    [Fact]
    public void InstalledEventsMatchTheOfficialLists()
    {
        Assert.DoesNotContain(AgentHookEvent.Notification, AgentNames.Installed(AgentKind.Codex));
        Assert.DoesNotContain(AgentHookEvent.Interrupt, AgentNames.Installed(AgentKind.Claude));
    }
}
