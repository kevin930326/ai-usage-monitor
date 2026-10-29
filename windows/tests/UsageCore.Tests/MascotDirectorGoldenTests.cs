using System.Globalization;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 角色畫面（MascotDirector）的跨平台一致性（ADR-0016 第 1 節）：讀 fixtures/mascot-director/cases.json 的事件串，
/// 在取樣時間算出姿勢、眼睛、表情、眨眼、視線、面板外形、內容、特效與漣漪，和 Swift
/// （apple/UsageKit/Tests/UsageKitTests/MascotDirectorGoldenTests.swift）產生的 golden.json 比對，數字容許 1e-6。
/// </summary>
public class MascotDirectorGoldenTests
{
    private static string Repo => LogicGoldenTests.RepoRoot;
    private static string Fixture(string name) => Path.Combine(Repo, "fixtures", "mascot-director", name);

    internal static MascotConfig Config() => MascotConfig.Decode(File.ReadAllText(Path.Combine(Repo, "shared", "mascot-anim.json")));

    private static readonly string[] Columns =
    [
        "t", "eyes", "mood", "blink", "gaze_yaw", "gaze_pitch", "panel_w", "panel_h", "panel_corner", "mini", "progress",
        "content_opacity", "content_offset", "status", "animating", "idle_moving", "sleep", "doze", "effects", "edge_flash", "ring0",
        .. MascotPose.AllProps.Select(p => MascotNames.Name(p)),
    ];

    private static string Number(double value)
    {
        var text = value.ToString("F6", CultureInfo.InvariantCulture);
        return text == "-0.000000" ? "0.000000" : text;
    }

    private static string Flag(bool value) => value ? "1" : "0";

    private static string Sample(MascotDirector director, long t)
    {
        var gaze = director.Gaze(t);
        var shape = director.PanelShape(t);
        var content = director.Content(t);
        var effects = director.Effects
            .Select(e => e.Progress(t) is { } progress
                ? (e.Kind switch
                {
                    MascotEffectKind.Heart => "heart",
                    MascotEffectKind.Bang => "bang",
                    MascotEffectKind.Ring ring => $"ring{ring.Level}",
                    _ => "?",
                }) + "@" + Number(progress)
                : null)
            .OfType<string>().ToList();
        var ring0 = director.Ripple is { } ripple && ripple.Rings.Count > 0 ? ripple.RingState(ripple.Rings[0], t) : null;
        var fields = new List<string>
        {
            t.ToString(CultureInfo.InvariantCulture), MascotNames.Name(director.Eyes(t)), MascotNames.Name(director.MoodAt(t)),
            Number(director.Blink(t)), Number(gaze.Yaw), Number(gaze.Pitch), Number(shape.Width), Number(shape.Height),
            Number(shape.Corner), Number(shape.MiniOpacity), Number(shape.Progress), Number(content.Opacity), Number(content.Offset),
            Number(director.StatusColor(t)), Flag(director.IsAnimating(t)), Flag(director.IsIdleMoving(t)), Flag(director.ShowsSleep),
            Flag(director.ShowsDoze), effects.Count == 0 ? "-" : string.Join(",", effects),
            Number(director.Ripple?.EdgeFlashAlpha(t, 290) ?? 0),
            ring0 is { } r ? $"{Number(r.Radius)}/{Number(r.Fade)}" : "-",
        };
        var pose = director.Pose(t);
        fields.AddRange(MascotPose.AllProps.Select(p => Number(pose[p])));
        return string.Join(" ", fields);
    }

    private static void Apply(JsonNode e, MascotDirector director)
    {
        var t = e["t"]!.GetValue<long>();
        string Name(string key) => e[key]!.GetValue<string>();
        bool On() => e["on"]?.GetValue<bool>() ?? false;
        switch (Name("e"))
        {
            case "open": director.Open(t, e["intro"]?.GetValue<bool>() ?? false); break;
            case "close": director.Close(t); break;
            case "request": director.Request(MascotNames.Parse<MascotRequest>(Name("name")), t); break;
            case "gesture": director.Gesture(MascotNames.Parse<MascotGesture>(Name("name")), t); break;
            case "click": director.Click(t, MascotNames.Parse<MascotRequest>(Name("choice"))); break;
            case "press": director.Press(t); break;
            case "release": director.Release(t); break;
            case "working": director.SetWorking(On(), t); break;
            case "idle": director.SetAgentIdle(On(), t); break;
            case "needs": director.SetNeedsYou(On(), t); break;
            case "background": director.SetBackground(On(), t); break;
            case "remote": director.SetRemoteWorking(On(), t); break;
            case "cheer": director.Cheer(t, e["react"]?.GetValue<bool>() ?? true); break;
            case "status": director.SetStatus(e["level"]?.GetValue<int>() ?? 0, t, e["react"]?.GetValue<bool>() ?? true); break;
            case "look": director.Look(t, e["dx"]?.GetValue<double>() ?? 0, e["dy"]?.GetValue<double>() ?? 0, snap: e["snap"]?.GetValue<bool>() ?? false); break;
            case "still": director.SetStill(On(), t); break;
            case "mood": director.SetMood(MascotNames.Parse<MascotMood>(Name("name"))); break;
            case "face": director.RequestFace(MascotNames.Parse<MascotMood>(Name("name")), t); break;
            default: throw new InvalidOperationException($"未知的事件 {Name("e")}");
        }
    }

    private static List<string> Run(JsonNode testCase, MascotConfig config)
    {
        var director = new MascotDirector(config);
        var times = new SortedSet<long>();
        foreach (var range in testCase["samples"]!.AsArray())
        {
            long from = range!["from"]!.GetValue<long>(), to = range["to"]!.GetValue<long>(), step = range["step"]!.GetValue<long>();
            for (var t = from; t <= to; t += step) times.Add(t);
        }
        var events = new Queue<JsonNode>(testCase["events"]!.AsArray().Select(e => e!));
        var samples = new List<string>();
        foreach (var t in times)
        {
            while (events.TryPeek(out var next) && next["t"]!.GetValue<long>() <= t)
            {
                events.Dequeue();
                director.Advance(next["t"]!.GetValue<long>());
                Apply(next, director);
            }
            director.Advance(t);
            samples.Add(Sample(director, t));
        }
        return samples;
    }

    /// <summary>文字欄位一樣、數字差不到 1e-6</summary>
    private static bool Matches(string a, string b)
    {
        var x = a.Split(' ');
        var y = b.Split(' ');
        if (x.Length != y.Length) return false;
        char[] separators = [',', '/', '@'];
        return x.Zip(y).All(pair =>
        {
            if (pair.First == pair.Second) return true;
            var ps = pair.First.Split(separators);
            var qs = pair.Second.Split(separators);
            return ps.Length == qs.Length && ps.Zip(qs).All(q => q.First == q.Second
                || (double.TryParse(q.First, NumberStyles.Float, CultureInfo.InvariantCulture, out var m)
                    && double.TryParse(q.Second, NumberStyles.Float, CultureInfo.InvariantCulture, out var n)
                    && Math.Abs(m - n) <= 1e-6 + 1e-9));
        });
    }

    /// <summary>貼邊的標籤只在會眨眼的表情排眨眼的計時器：過期、用完、擔心與睡覺、工作中不眨（Codex C-01，第 5 部分第二輪）</summary>
    [Fact]
    public void TabBlinksOnlyWithPillEyes()
    {
        var director = new MascotDirector(Config());
        director.Advance(10_000);
        Assert.True(director.CanBlink(10_000, tab: true));
        foreach (var mood in new[] { MascotMood.Stale, MascotMood.Out, MascotMood.Worried })
        {
            director.SetMood(mood);
            Assert.False(director.CanBlink(10_000, tab: true), mood.ToString());
            Assert.Equal(0, director.Blink(director.NextBlink(10_000) + 60, tab: true));
        }
        director.SetMood(MascotMood.Normal);
        director.SetWorking(true, 10_000);
        director.Advance(12_000);
        Assert.False(director.CanBlink(12_000, tab: true));
    }

    [Fact]
    public void GoldenMatchesDirector()
    {
        var config = Config();
        var input = JsonNode.Parse(File.ReadAllText(Fixture("cases.json")))!;
        var golden = JsonNode.Parse(File.ReadAllText(Fixture("golden.json")))!;
        Assert.Equal(string.Join(" ", Columns), golden["columns"]!.GetValue<string>());
        var expected = golden["cases"]!.AsArray();
        var cases = input["cases"]!.AsArray();
        Assert.Equal(expected.Count, cases.Count);
        for (var i = 0; i < cases.Count; i++)
        {
            var name = cases[i]!["name"]!.GetValue<string>();
            Assert.Equal(name, expected[i]!["name"]!.GetValue<string>());
            var want = expected[i]!["samples"]!.AsArray().Select(s => s!.GetValue<string>()).ToList();
            var got = Run(cases[i]!, config);
            Assert.Equal(want.Count, got.Count);
            for (var j = 0; j < want.Count; j++)
            {
                Assert.True(Matches(want[j], got[j]), $"{name} 第 {j} 個取樣：\n預期 {want[j]}\n實際 {got[j]}");
            }
        }
    }

    [Fact]
    public void ConfigDecodesWholeFile()
    {
        var config = Config();
        Assert.Equal(250, config.Panel.Collapsed.Width);
        Assert.Equal(190, config.Panel.OpenSpring.Stiffness);
        Assert.Equal(33, config.Hero.Card.Radius);
        Assert.Equal(560, config.Ripple.Particles);
        Assert.Equal([40, 190, 360, 560], config.Intro.RingsAt);
        Assert.Equal([0x9A, 0x9A, 0xA6], MascotConfig.Rgb(config.Hero.Keyboard.Color));
        Assert.Equal([0, 0, 0], MascotConfig.Rgb("#zzzzzz"));
    }

    [Fact]
    public void LooksDecodeAndMatchMac()
    {
        var looks = MascotLooks.Decode(File.ReadAllText(Path.Combine(Repo, "shared", "mascot-looks.json")));
        Assert.NotEmpty(looks.Looks);
        Assert.Equal(looks.Looks.Count, looks.Looks.Select(l => l.Id).Distinct().Count());
        var deepSpace = looks.Look("T5")!;
        Assert.Equal(MascotLookStyle.Linear, deepSpace.Style);
        Assert.Equal([0xEA, 0xF0, 0xFF], deepSpace.Eye!);
        Assert.Null(looks.Look(null));
        Assert.Contains(looks.Looks, l => l.Style.IsGrid());
        Assert.Throws<System.Text.Json.JsonException>(() => MascotLooks.Decode(
            """{"version":1,"groups":[{"id":"a","name":"A"}],"looks":[{"id":"x","name":"X","group":"a","style":"solid","light":"#FFFFFF","glow":"#000000"}]}"""));
    }

    [Fact]
    public void ThinkingDotsMatchMac()
    {
        // 同 Swift 的 MascotThinkingTests：一輪 2π·310 ms（敲鍵盤）走 2 次 0→3 顆，每步約 243 ms
        var loop = 2 * Math.PI * 310;
        Assert.Equal(loop / 8, MascotThinking.StepMs(loop), 9);
        Assert.Equal(0, MascotThinking.Dots(0, loop));
        Assert.Equal(1, MascotThinking.Dots(250, loop));
        Assert.Equal(3, MascotThinking.Dots((long)(loop / 8 * 3) + 1, loop));
        Assert.Equal(0, MascotThinking.Dots((long)loop + 1, loop));
    }

    [Fact]
    public void GesturesDetectCircleShakeAndHover()
    {
        var config = Config();
        var detector = new MascotGestureDetector(config);
        MascotGesture? found = null;
        // 繞角色兩圈多（半徑 40，每 16 ms 轉 0.25 rad：水平每格最多 10 px，不到甩動的門檻）
        for (var i = 0; i < 200 && found is null; i++)
        {
            var a = i * 0.25;
            found = detector.Move(100 + 40 * Math.Cos(a), 100 + 40 * Math.Sin(a), i * 16, 100, 100, 33, canDetect: true);
        }
        Assert.Equal(MascotGesture.Circle, found);

        detector.Reset();
        found = null;
        for (var i = 0; i < 12 && found is null; i++)
            found = detector.Move(i % 2 == 0 ? 60 : 140, 100, 1000 + i * 16, 100, 100, 33, canDetect: true);
        Assert.Equal(MascotGesture.Shake, found);

        detector.Reset();
        Assert.Null(detector.Move(100, 100, 5000, 100, 100, 33, canDetect: true));
        Assert.Equal(MascotGesture.Hover, detector.CheckHover(5000 + config.Interaction.HoverShyMs + 1, canDetect: true));
        Assert.Null(detector.Move(100, 100, 9000, 100, 100, 33, canDetect: false));
        Assert.True(detector.Hits(120, 100, 100, 100, 33));
        Assert.False(detector.Hits(200, 100, 100, 100, 33));
    }
}
