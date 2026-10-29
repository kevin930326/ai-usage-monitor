using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 角色養成的跨平台一致性（ADR-0020）：讀 fixtures/level/cases.json，用 UsageCore 的 MascotLevel（有 stored 時先以
/// MascotLevelLedger 和 level.json 的內容合併）算出結果，
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
        Dictionary<string, long>? stored = null;
        if (c["stored"] is { } raw)
        {
            stored = MascotLevelLedger.Decode(raw.GetValue<string>());
            if (stored is not null) days = MascotLevelLedger.Merge(stored, days);
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
        if (c["stored"] is not null) result["stored_ok"] = stored is not null;
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

    /// <summary>清除歷史（level_days 清空）後，level.json 讓等級不變（ADR-0020 第 1 節，2026-10-29 修訂）</summary>
    [Fact]
    public void ClearingHistoryKeepsLevel()
    {
        var cases = JsonNode.Parse(File.ReadAllText(Level("cases.json")))!["cases"]!.AsArray();
        JsonNode Result(string name) => Run(cases.First(c => c!["name"]!.GetValue<string>() == name)!)["result"]!;
        Assert.True(JsonNode.DeepEquals(Result("before-clear-history"), Result("clear-history-keeps-level")));
        Assert.True(Result("before-clear-history")["level"]!.GetValue<int>() >= 2);
    }

    [Fact]
    public void LedgerFileKeepsDaysAfterHistoryIsCleared()
    {
        var folder = Path.Combine(Path.GetTempPath(), "aum-level-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var file = Path.Combine(folder, MascotLevelLedger.FileName);
            var days = new Dictionary<string, long> { ["2026-10-27"] = 50_000, ["2026-10-28"] = 80_000, ["2026-10-29"] = 20_000 };
            Assert.Equal(days, MascotLevelLedger.Update(file, days, "2026-10-29").Days);
            Assert.Equal(days, MascotLevelLedger.Update(file, new Dictionary<string, long>(), "2026-10-29").Days);
            Assert.Equal(days, MascotLevelLedger.Decode(File.ReadAllText(file)));
            var stamp = File.GetLastWriteTimeUtc(file);
            Assert.Equal(days, MascotLevelLedger.Update(file, new Dictionary<string, long> { ["2026-10-28"] = 1 }, "2026-10-29").Days);
            Assert.Equal(stamp, File.GetLastWriteTimeUtc(file));

            // 壞掉：改名保留、從歷史重建
            File.WriteAllText(file, "{\"days\": {");
            Assert.Equal(days, MascotLevelLedger.Update(file, days, "2026-10-29").Days);
            Assert.True(File.Exists(Path.Combine(folder, MascotLevelLedger.CorruptName)));
            Assert.Equal(days, MascotLevelLedger.Decode(File.ReadAllText(file)));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>讀不到時 Saved 為 false（清除歷史與顯示靠它判斷；Fable F-01、F-08）</summary>
    [Fact]
    public void LedgerReportsWhenItCannotBeRead()
    {
        var folder = Path.Combine(Path.GetTempPath(), "aum-level-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, MascotLevelLedger.FileName);
        var days = new Dictionary<string, long> { ["2026-10-29"] = 20_000 };
        try
        {
            Assert.True(MascotLevelLedger.Update(file, days, "2026-10-29").Saved);
            Assert.True(MascotLevelLedger.Update(file, new Dictionary<string, long>(), "2026-10-29").Saved);
            if (OperatingSystem.IsWindows())
            {
                using var held = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                Assert.False(MascotLevelLedger.Update(file, days, "2026-10-29").Saved);
            }
            else
            {
                File.SetUnixFileMode(file, UnixFileMode.None);
                Assert.False(MascotLevelLedger.Update(file, days, "2026-10-29").Saved);
                File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            Assert.False(File.Exists(file + ".tmp"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
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
