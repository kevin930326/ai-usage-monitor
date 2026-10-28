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
            $"{(s.Need is { } n ? $"({AgentNames.Name(n)})" : "")}@{s.Since}");
        var top = sessions.Top(now) is { } t ? $"{AgentNames.Name(t.Ai)}/{t.Id[..4]}" : "none";
        return $"top={top} [{string.Join(", ", list)}]";
    }

    private static string[] Run(JsonNode testCase)
    {
        var sessions = new AgentSessions(testCase["idle_after_ms"]?.GetValue<long>() ?? 300_000);
        var log = new List<string>();
        foreach (var e in testCase["events"]!.AsArray())
        {
            var t = e!["t"]!.GetValue<long>();
            switch (e["e"]!.GetValue<string>())
            {
                case "msg":
                    var ai = e["ai"]!.GetValue<string>();
                    var ev = e["ev"]!.GetValue<string>();
                    var need = e["need"]?.GetValue<string>() ?? "";
                    var sub = e["sub"]?.GetValue<bool>() ?? false;
                    sessions.Apply(new AgentHookMessage(AgentNames.Kind(ai)!.Value, AgentNames.Event(ev)!.Value, AgentNames.Need(need),
                                                        e["sid"]!.GetValue<string>(), t, e["dir"]?.GetValue<string>() ?? "", sub), t);
                    log.Add($"{t} {ai} {ev}{(need.Length > 0 ? $"({need})" : "")}{(sub ? "[sub]" : "")} → {Describe(sessions, t)}");
                    break;
                case "activity":
                    var (working, idle) = sessions.Activity(t, new Dictionary<AgentKind, (bool, bool)>());
                    log.Add($"{t} activity working={(working ? "true" : "false")} idle={(idle ? "true" : "false")}");
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
    public void EncodedMessageRoundTrips()
    {
        var message = new AgentHookMessage(AgentKind.Codex, AgentHookEvent.PostToolUseFailure, AgentNeed.Permission, "0123456789abcdef",
                                           long.MaxValue, new string('名', AgentHookInput.MaxFolder));
        var data = message.Encoded();
        Assert.True(data.Length <= AgentHookMessage.MaxLength);
        Assert.Equal(message, AgentHookMessage.Parse(data));
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
