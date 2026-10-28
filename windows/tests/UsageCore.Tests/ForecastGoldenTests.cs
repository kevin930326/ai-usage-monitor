using System.Globalization;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 額度預測的跨平台一致性（ADR-0018 第 1 節）：讀 fixtures/forecast/cases.json，用 UsageCore 的 QuotaForecast 算出結果，
/// 和 Swift（apple/UsageKit/Tests/UsageKitTests/ForecastGoldenTests.swift）產生的 golden.json 比對。
/// </summary>
public class ForecastGoldenTests
{
    private static string Forecast(string name) => Path.Combine(LogicGoldenTests.RepoRoot, "fixtures", "forecast", name);

    private static JsonObject Run(JsonNode c, DateTimeOffset now)
    {
        var w = c["window"]!;
        var id = w["id"]!.GetValue<string>();
        double? windowResets = w["resets_min"]?.GetValue<double>();
        DateTimeOffset At(double minutes) => now.AddSeconds(minutes * 60);
        var samples = new List<QuotaSample>();
        foreach (var s in c["series"]!.AsArray())
        {
            int from = s!["from_min"]!.GetValue<int>(), to = s["to_min"]!.GetValue<int>(), every = s["every_min"]!.GetValue<int>();
            double start = s["start"]!.GetValue<double>(), end = s["end"]!.GetValue<double>();
            double? resets = s["resets_min"]?.GetValue<double>() ?? windowResets;
            for (var t = from; t <= to; t += every)
            {
                var used = start + (end - start) * (t - from) / (to - from);
                samples.Add(new QuotaSample(At(t), "claude", id, used, resets is { } r ? At(r) : null));
            }
        }
        var window = new UsageWindow(id, id, w["used_pct"]!.GetValue<double>(), windowResets is { } wr ? At(wr) : null,
                                     w["hidden"]?.GetValue<bool>() ?? false);
        var forecast = QuotaForecast.From(window, "claude", new QuotaHistory(samples), c["stale"]?.GetValue<bool>() ?? false, now);
        var result = new JsonObject { ["name"] = c["name"]!.GetValue<string>() };
        if (forecast is not null)
        {
            var r = new JsonObject
            {
                ["exhausts_in_min"] = (int)Math.Floor((forecast.ExhaustsAt - now).TotalSeconds / 60),
                ["urgent"] = forecast.Urgent,
            };
            if (forecast.Faster is { } f) r["faster"] = f;
            result["result"] = r;
        }
        return result;
    }

    [Fact]
    public void MatchesGolden()
    {
        var input = JsonNode.Parse(File.ReadAllText(Forecast("cases.json")))!;
        var now = DateTimeOffset.Parse(input["now"]!.GetValue<string>(), CultureInfo.InvariantCulture);
        var golden = JsonNode.Parse(File.ReadAllText(Forecast("golden.json")))!.AsArray();
        var cases = input["cases"]!.AsArray();
        Assert.Equal(golden.Count, cases.Count);
        for (var i = 0; i < cases.Count; i++)
        {
            var actual = Run(cases[i]!, now);
            var expected = golden[i]!;
            Assert.True(JsonNode.DeepEquals(expected, actual), $"{actual["name"]}：\n預期 {expected.ToJsonString()}\n實際 {actual.ToJsonString()}");
        }
    }
}
