using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 跨平台的計算一致性（ADR-0015 第 4 節）：讀 repo 根目錄的 fixtures/logic/cases.json，用 C# 的 UsageCore 算出和
/// Swift（apple/UsageKit/Tests/UsageKitTests/LogicGoldenTests.swift）同樣的欄位，與 Swift 產生的 golden.json 逐鍵比對。
/// 欄位名稱、四捨五入（9 位小數、用完時間到整秒）與 Swift 的輸出相同。
/// </summary>
public class LogicGoldenTests
{
    internal static string RepoRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "fixtures", "logic"))) dir = dir.Parent;
            return dir?.FullName ?? throw new DirectoryNotFoundException("找不到 repo 根目錄的 fixtures/logic");
        }
    }

    private static string Fixture(string name) => Path.Combine(RepoRoot, "fixtures", "logic", name);

    [Fact]
    public void GoldenMatchesUsageCore()
    {
        var expected = JsonNode.Parse(File.ReadAllText(Fixture("golden.json")))!;
        var actual = Compute(JsonNode.Parse(File.ReadAllText(Fixture("cases.json")))!);
        var differences = new List<string>();
        Compare(expected, actual, "$", differences);
        Assert.True(differences.Count == 0,
                    "C# 的計算與 golden.json（Swift）不同：\n" + string.Join("\n", differences.Take(30)));
    }

    [Fact]
    public void EveryCaseIsCovered()
    {
        // 新增情境時兩邊都要重新產生：golden 的情境數與輸入相同
        var cases = JsonNode.Parse(File.ReadAllText(Fixture("cases.json")))!["cases"]!.AsArray();
        var golden = JsonNode.Parse(File.ReadAllText(Fixture("golden.json")))!["cases"]!.AsArray();
        Assert.Equal(cases.Count, golden.Count);
        Assert.True(cases.Count >= 20);
    }

    internal static JsonNode Compute(JsonNode input)
    {
        var epoch = DateTimeOffset.FromUnixTimeSeconds(1_793_007_000);
        var cases = new JsonArray();
        foreach (var c in input["cases"]!.AsArray()) cases.Add(CaseOutput(c!));
        var tokens = new JsonArray();
        foreach (var v in input["token_format"]!.AsArray())
        {
            var value = v!.GetValue<long>();
            tokens.Add(new JsonObject { ["value"] = value, ["short"] = TokenFormat.Short(value), ["full"] = TokenFormat.Full(value) });
        }
        var countdown = new JsonArray();
        foreach (var v in input["countdown_seconds"]!.AsArray())
        {
            var s = v!.GetValue<double>();
            countdown.Add(new JsonObject { ["seconds"] = s, ["text"] = ResetCountdown.Text(epoch.AddSeconds(s), epoch) });
        }
        var updated = new JsonArray();
        foreach (var v in input["updated_seconds"]!.AsArray())
        {
            var s = v!.GetValue<double>();
            updated.Add(new JsonObject { ["seconds"] = s, ["text"] = ResetCountdown.UpdatedText(epoch.AddSeconds(-s), epoch) });
        }
        var duration = new JsonArray();
        foreach (var v in input["duration_seconds"]!.AsArray())
        {
            var s = v!.GetValue<long>();
            duration.Add(new JsonObject { ["seconds"] = s, ["text"] = TokenFormat.Duration(s) });
        }
        var tokenCases = new JsonArray();
        foreach (var c in input["token_cases"]!.AsArray()) tokenCases.Add(LogicGoldenHistory.TokenCase(c!));
        return new JsonObject
        {
            ["cases"] = cases, ["token_format"] = tokens, ["countdown"] = countdown, ["updated"] = updated,
            ["duration"] = duration, ["token_cases"] = tokenCases,
        };
    }

    private static JsonObject CaseOutput(JsonNode c)
    {
        var now = Parse(c["now"]!.GetValue<string>());
        var snapshot = UsageDecoder.Decode(c["snapshot"]!.ToJsonString());
        var stale = snapshot.IsStale(now);
        var samples = new List<QuotaSample>();
        if (c["samples"] is JsonArray rows)
        {
            foreach (var r in rows)
            {
                samples.Add(new QuotaSample(Parse(r!["ts"]!.GetValue<string>()), r["provider"]!.GetValue<string>(),
                                            r["window"]!.GetValue<string>(), r["used_pct"]!.GetValue<double>(),
                                            r["resets_at"] is JsonValue ra ? Parse(ra.GetValue<string>()) : null));
            }
        }
        var runs = new List<CollectorRun>();
        if (c["runs"] is JsonArray runRows)
        {
            foreach (var r in runRows)
            {
                runs.Add(new CollectorRun(Parse(r!["ts"]!.GetValue<string>()), r["ok"]?.GetValue<int>() ?? 1, r["runs"]?.GetValue<int>() ?? 1));
            }
        }
        var history = new QuotaHistory(samples, runs);
        var chosen = snapshot.Window(WindowChoice.Parse(c["choice"]?.GetValue<string>()), now);
        var windows = new JsonArray();
        foreach (var provider in snapshot.OrderedProviderKeys)
        {
            foreach (var window in snapshot.Providers[provider].Windows)
            {
                var item = new ProviderWindow(provider, window);
                var rate = history.RecentRate(provider, window.Id, now);
                windows.Add(new JsonObject
                {
                    ["key"] = item.Key,
                    ["display_name"] = item.DisplayName,
                    ["hidden"] = window.Hidden,
                    ["is_reset"] = window.IsReset(now),
                    ["effective_used_pct"] = Round9(window.EffectiveUsedPct(now)),
                    ["effective_remaining_pct"] = Round9(window.EffectiveRemainingPct(now)),
                    ["remaining_rounded"] = SwiftMath.Round(window.EffectiveRemainingPct(now)),
                    ["severity"] = window.EffectiveSeverity(now) == UsageSeverity.Critical ? "critical" : "normal",
                    ["state"] = RingStates.Name(RingStates.Of(window, stale, now)),
                    ["duration"] = window.Duration,
                    ["elapsed_fraction"] = Round9(window.ElapsedFraction(now)),
                    ["time_remaining_fraction"] = Round9(window.TimeRemainingFraction(now)),
                    ["expected_remaining_pct"] = Round9(window.ExpectedRemainingPct(now)),
                    ["expected_description"] = window.ExpectedRemainingDescription(now),
                    ["pace"] = Pace(UsagePace.Average(window, stale, now)),
                    ["pace_history"] = Pace(UsagePace.WithHistory(window, provider, history, stale, now)),
                    ["recent_rate_per_hour"] = Round9(rate * 3600),
                    ["countdown"] = window.ResetsAt is { } r ? ResetCountdown.Text(r, now) : null,
                });
            }
        }
        var tightest = snapshot.TightestWindow(now);
        return new JsonObject
        {
            ["name"] = c["name"]!.GetValue<string>(),
            ["stale"] = stale,
            ["has_no_providers"] = snapshot.HasNoProviders,
            ["ordered_providers"] = new JsonArray(snapshot.OrderedProviderKeys.Select(k => (JsonNode?)JsonValue.Create(k)).ToArray()),
            ["tightest"] = tightest?.Key,
            ["chosen"] = chosen?.Key,
            ["chosen_state"] = chosen is null ? null : RingStates.Name(RingStates.Of(chosen.Window, stale, now)),
            ["least_label"] = tightest?.LeastRemainingAccessibilityLabel(now),
            ["windows"] = windows,
            ["history"] = LogicGoldenHistory.History(c, snapshot, history, now),
        };
    }

    private static JsonObject? Pace(UsagePace? pace) => pace is null ? null : new JsonObject
    {
        ["ahead_by"] = Round9(pace.AheadBy),
        ["exhausts_at"] = pace.ExhaustsAt is { } at ? SwiftMath.Round(at.ToUnixTimeMilliseconds() / 1000.0) : null,
        ["too_fast"] = pace.IsTooFast,
    };

    internal static double? Round9(double? x) => x is { } v ? Math.Round(v * 1e9, MidpointRounding.AwayFromZero) / 1e9 : null;

    internal static DateTimeOffset Parse(string s) =>
        UsageDecoder.TryParseIso(s, out var d) ? d : throw new FormatException(s);

    internal static void Compare(JsonNode? expected, JsonNode? actual, string path, List<string> differences)
    {
        switch (expected, actual)
        {
            case (null, null):
                return;
            case (JsonObject e, JsonObject a):
                foreach (var key in e.Select(p => p.Key).Union(a.Select(p => p.Key)).OrderBy(k => k, StringComparer.Ordinal))
                {
                    if (!e.ContainsKey(key) || !a.ContainsKey(key))
                    {
                        differences.Add($"{path}.{key}：{(e.ContainsKey(key) ? "C# 沒有" : "golden 沒有")}");
                        continue;
                    }
                    Compare(e[key], a[key], $"{path}.{key}", differences);
                }
                return;
            case (JsonArray e, JsonArray a):
                if (e.Count != a.Count)
                {
                    differences.Add($"{path}：長度 {e.Count} ≠ {a.Count}");
                    return;
                }
                for (var i = 0; i < e.Count; i++) Compare(e[i], a[i], $"{path}[{i}]", differences);
                return;
            case (JsonValue e, JsonValue a):
                var ek = e.GetValueKind();
                var ak = a.GetValueKind();
                if (ek == JsonValueKind.Number && ak == JsonValueKind.Number)
                {
                    // 數字一律以文字轉成 double 比較：解析出來的 JsonValue 與程式建立的（long、double）型別不同
                    var ev = double.Parse(e.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);
                    var av = double.Parse(a.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);
                    if (Math.Abs(ev - av) > 1e-9) differences.Add($"{path}：{e.ToJsonString()} ≠ {a.ToJsonString()}");
                    return;
                }
                if (ek != ak || e.ToJsonString() != a.ToJsonString()) differences.Add($"{path}：{e.ToJsonString()} ≠ {a.ToJsonString()}");
                return;
            default:
                differences.Add($"{path}：{expected?.ToJsonString() ?? "null"} ≠ {actual?.ToJsonString() ?? "null"}");
                return;
        }
    }
}
