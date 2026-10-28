using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 角色養成的跨平台一致性（ADR-0020）：讀 fixtures/level/cases.json，用 UsageCore 的 MascotLevel 算出結果，
/// 和 Swift（apple/UsageKit/Tests/UsageKitTests/LevelGoldenTests.swift）產生的 golden.json 比對。
/// </summary>
public class LevelGoldenTests
{
    private static string Level(string name) => Path.Combine(LogicGoldenTests.RepoRoot, "fixtures", "level", name);

    private static JsonObject Run(JsonNode c)
    {
        var days = new Dictionary<string, long>();
        foreach (var (day, tokens) in c["days"]!.AsObject()) days[day] = tokens!.GetValue<long>();
        foreach (var r in c["runs"]?.AsArray() ?? [])
        {
            var start = DateOnly.ParseExact(r!["from"]!.GetValue<string>(), "yyyy-MM-dd");
            for (var i = 0; i < r["count"]!.GetValue<int>(); i++)
                days[start.AddDays(i).ToString("yyyy-MM-dd")] = r["tokens"]!.GetValue<long>();
        }
        var level = MascotLevel.From(days, c["today"]!.GetValue<string>());
        var result = new JsonObject { ["name"] = c["name"]!.GetValue<string>() };
        if (level is not null)
        {
            result["result"] = new JsonObject
            {
                ["active_days"] = level.ActiveDays,
                ["current_streak"] = level.CurrentStreak,
                ["level"] = level.Level,
                ["longest_streak"] = level.LongestStreak,
                ["to_next"] = level.ToNext,
                ["xp"] = level.Xp,
            };
        }
        return result;
    }

    [Fact]
    public void MatchesGolden()
    {
        var cases = JsonNode.Parse(File.ReadAllText(Level("cases.json")))!["cases"]!.AsArray();
        var golden = JsonNode.Parse(File.ReadAllText(Level("golden.json")))!.AsArray();
        Assert.Equal(golden.Count, cases.Count);
        for (var i = 0; i < cases.Count; i++)
            Assert.True(JsonNode.DeepEquals(golden[i], Run(cases[i]!)), $"{golden[i]!["name"]}: {Run(cases[i]!).ToJsonString()}");
    }

    [Fact]
    public void ThresholdsAndDayNumbers()
    {
        Assert.Equal(new long[] { 50, 150, 500, 2_250, 9_500, 21_750 }, new[] { 2, 3, 5, 10, 20, 30 }.Select(MascotLevel.Threshold));
        Assert.Equal(0, MascotLevel.DayNumber("1970-01-01"));
        Assert.Equal(20_389, MascotLevel.DayNumber("2025-10-28"));
        Assert.Null(MascotLevel.DayNumber("2026-02-29"));
        Assert.Equal(0.2, MascotLevel.From(new Dictionary<string, long> { ["2026-10-29"] = 1 }, "2026-10-29")!.Progress);
    }
}
