using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 角色狀態機的跨平台一致性（ADR-0016）：讀 fixtures/mascot/cases.json 的事件串，用 UsageCore 的 MascotMachine
/// 排出播放紀錄，和 Swift（apple/UsageKit/Tests/UsageKitTests/MascotGoldenTests.swift）產生的 golden.json 比對。
/// 時間參數讀 shared/mascot-anim.json。
/// </summary>
public class MascotGoldenTests
{
    private static string Repo => LogicGoldenTests.RepoRoot;
    private static string Mascot(string name) => Path.Combine(Repo, "fixtures", "mascot", name);
    private static MascotTiming Timing() =>
        MascotTiming.FromConfig(File.ReadAllText(Path.Combine(Repo, "shared", "mascot-anim.json")));

    private static JsonObject Run(JsonNode testCase, MascotTiming timing)
    {
        var machine = new MascotMachine(timing);
        foreach (var e in testCase["events"]!.AsArray())
        {
            var t = e!["t"]!.GetValue<long>();
            switch (e["e"]!.GetValue<string>())
            {
                case "open": machine.Open(t, e["intro"]?.GetValue<bool>() ?? false); break;
                case "close": machine.Close(t); break;
                case "request": machine.Request(MascotNames.Parse<MascotRequest>(e["name"]!.GetValue<string>()), t); break;
                case "gesture": machine.Gesture(MascotNames.Parse<MascotGesture>(e["name"]!.GetValue<string>()), t); break;
                case "click": machine.Click(t, MascotNames.Parse<MascotRequest>(e["choice"]!.GetValue<string>())); break;
                case "press": machine.Press(t); break;
                case "release": machine.Release(t); break;
                case "move": machine.Move(t); break;
                case "working": machine.SetWorking(e["on"]?.GetValue<bool>() ?? false, t); break;
                case "idle": machine.SetAgentIdle(e["on"]?.GetValue<bool>() ?? false, t); break;
                case "status": machine.SetStatus(e["level"]?.GetValue<int>() ?? 0, t, e["react"]?.GetValue<bool>() ?? true); break;
                case "silence": machine.Silence(t); break;
                case "advance": machine.Advance(t); break;
                default: throw new InvalidOperationException($"未知的事件 {e["e"]}");
            }
        }
        var final = new JsonObject
        {
            ["mode"] = MascotNames.Name(machine.Mode),
            ["open"] = machine.IsOpen,
            ["status"] = machine.StatusLevel,
        };
        // Swift 的 JSONEncoder 不輸出 nil 欄位
        if (machine.Playing is { } playing) final["playing"] = MascotNames.Name(playing.Animation);
        if (machine.Pending is { } pending) final["pending"] = MascotNames.Name(pending);
        if (machine.Queued is { } queued) final["queued"] = MascotNames.Name(queued);
        return new JsonObject
        {
            ["final"] = final,
            ["log"] = new JsonArray(machine.Log.Select(l => (JsonNode)JsonValue.Create(l.ToString())!).ToArray()),
            ["name"] = testCase["name"]!.GetValue<string>(),
        };
    }

    [Fact]
    public void GoldenMatchesMachine()
    {
        var timing = Timing();
        var cases = JsonNode.Parse(File.ReadAllText(Mascot("cases.json")))!["cases"]!.AsArray();
        var golden = JsonNode.Parse(File.ReadAllText(Mascot("golden.json")))!["cases"]!.AsArray();
        Assert.Equal(cases.Count, golden.Count);
        for (var i = 0; i < cases.Count; i++)
        {
            var actual = Run(cases[i]!, timing);
            var expected = golden[i]!;
            Assert.True(JsonNode.DeepEquals(expected, actual),
                        $"{actual["name"]}：\n預期 {expected["log"]!.ToJsonString()}\n{expected["final"]!.ToJsonString()}\n" +
                        $"實際 {actual["log"]!.ToJsonString()}\n{actual["final"]!.ToJsonString()}");
        }
    }

    [Fact]
    public void ConfigHasEveryAnimationDuration()
    {
        var timing = Timing();
        foreach (var animation in Enum.GetValues<MascotAnimation>())
        {
            var key = MascotTiming.DurationKey(animation);
            Assert.True(timing.DurationsMs.ContainsKey(key), $"mascot-anim.json 缺少 {key} 的長度");
        }
        Assert.Equal(900, timing.Duration(MascotAnimation.Hop));
        Assert.Equal(2900, timing.Duration(MascotAnimation.Dizzy));
        Assert.Equal(360, timing.RestBeforeQueuedMs);
        Assert.Equal(5, timing.ClicksForDizzy);
        Assert.Equal(4680, timing.IntroInteractiveMs);
    }

    [Fact]
    public void NamesMatchSwiftRawValues()
    {
        Assert.Equal("hop", MascotNames.Name(MascotAnimation.Hop));
        Assert.Equal(MascotRequest.Giggle, MascotNames.Parse<MascotRequest>("giggle"));
        Assert.Throws<ArgumentException>(() => MascotNames.Parse<MascotRequest>("Giggle"));
        Assert.Throws<ArgumentException>(() => MascotNames.Parse<MascotRequest>("sleep"));
    }

    [Fact]
    public void AdvanceIsIdempotentAndOrdered()
    {
        var machine = new MascotMachine(Timing());
        machine.Open(0, intro: false);
        machine.Request(MascotRequest.Shy, 10);
        machine.Advance(5000);
        var once = machine.Log.ToArray();
        machine.Advance(5000);
        machine.Advance(4000);
        Assert.Equal(once, machine.Log);
        Assert.Equal(5000, machine.Now);
        Assert.True(once.Zip(once.Skip(1)).All(p => p.First.Time <= p.Second.Time));
        machine.Press(3000);
        machine.Advance(6000);
        Assert.True(machine.Log.Zip(machine.Log.Skip(1)).All(p => p.First.Time <= p.Second.Time));
    }

    [Fact]
    public void MissingTimingKeyFails()
    {
        var json = File.ReadAllText(Path.Combine(Repo, "shared", "mascot-anim.json")).Replace("rest_before_queued_ms", "renamed");
        Assert.ThrowsAny<JsonException>(() => MascotTiming.FromConfig(json));
    }
}
