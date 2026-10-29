using System.Diagnostics;
using System.Security.Cryptography;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// HistoryReader 以收集器自己的程式建立的 history.sqlite3 測試（make_history_db.py）：讀到的內容、唯讀（主檔不變）、
/// 收集器寫入中也讀得到（WAL）、讀完不佔住檔案（Windows 上收集器才能改名）、版本與損毀。
/// 需要 Python 3（CI 的三個平台與 verify-all 都有）；不碰真實的資料夾。
/// </summary>
public sealed class HistoryReaderTests : IDisposable
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_793_007_000);  // 2026-10-26T09:30Z
    private readonly string folder = Directory.CreateTempSubdirectory("aum-history-").FullName;
    private string DbPath => Path.Combine(folder, "history.sqlite3");

    public void Dispose()
    {
        try { Directory.Delete(folder, true); } catch (IOException) { }
    }

    private static string Python => Environment.GetEnvironmentVariable("AUM_PYTHON") ?? (OperatingSystem.IsWindows() ? "python" : "python3");

    private static ProcessStartInfo Script(params string[] args)
    {
        var info = new ProcessStartInfo(Python)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
        };
        info.ArgumentList.Add("-X");
        info.ArgumentList.Add("utf8");
        info.ArgumentList.Add(Path.Combine(LogicGoldenTests.RepoRoot, "windows", "tests", "UsageCore.Tests", "make_history_db.py"));
        foreach (var a in args) info.ArgumentList.Add(a);
        return info;
    }

    private void Make(string mode)
    {
        using var p = Process.Start(Script(DbPath, mode, Now.ToUnixTimeSeconds().ToString()))!;
        p.StandardInput.Close();
        var error = p.StandardError.ReadToEnd();
        p.WaitForExit();
        Assert.True(p.ExitCode == 0, $"make_history_db.py {mode} 失敗：{error}");
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    [Fact]
    public void MissingFileIsNotCreated()
    {
        var result = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
        Assert.Equal(HistoryReader.Status.Missing, result.Status);
        Assert.False(File.Exists(DbPath));
    }

    /// <summary>Windows 的角色等級只算這台：record_days 各服務相加，不含其他電腦的 daily_tokens（ADR-0020 第 4 節）</summary>
    [Fact]
    public void LocalLevelDaysOnlyCountThisComputer()
    {
        Assert.Null(new HistoryReader(DbPath).LocalLevelDays());
        Assert.False(File.Exists(DbPath));
        Make("full");
        var hash = Hash(DbPath);
        Assert.Equal(new Dictionary<string, long> { ["2026-10-25"] = 150 }, new HistoryReader(DbPath).LocalLevelDays());
        Assert.Equal(hash, Hash(DbPath));
    }

    [Fact]
    public void ReadsWhatTheCollectorWrote()
    {
        Make("full");
        var result = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc, hourly: true);
        Assert.Equal(HistoryReader.Status.Ready, result.Status);
        Assert.Equal(HistoryReader.SupportedSchema, result.SchemaVersion);

        // 額度：最近 8 天（9 天前的那筆不讀）
        var samples = result.History.SamplesFor("claude", "five_hour");
        Assert.Equal(6, samples.Count);
        Assert.Equal(22.5, samples[^1].UsedPct);
        Assert.Equal(Now.AddHours(2), samples[0].ResetsAt);
        Assert.Empty(result.History.SamplesFor("claude", "weekly"));
        Assert.Contains(result.History.Runs, r => r.Runs == 12 && r.Ok == 11);
        Assert.NotNull(result.History.RecentRate("claude", "five_hour", Now));

        // Token：本機的列 Device 是空字串；一年前的列不讀；每小時只讀這台電腦的
        var t = result.Tokens;
        Assert.Equal(2, t.Days.Count);
        Assert.Contains(t.Days, d => d.Device == TokenDevices.Local && d.Counts == new TokenCounts(100, 20, 5000, 30, 4) && d.LongestTaskSeconds == 400);
        Assert.Contains(t.Days, d => d.Device == "dev-desk" && d.Provider == "codex");
        Assert.Single(t.Hours);
        Assert.Equal(13, t.Hours[0].Hour);
        Assert.Equal(123456, t.Records["total_tokens"].Value);
        Assert.Equal("2026-10-01", t.Records["best_day_tokens"].Day);
        Assert.Equal(150, t.RecordDays["2026-10-25"]["claude"]);
        Assert.Equal(90, t.RetentionDays);
        Assert.True(t.FirstScanDone);
        Assert.Equal(100, t.FirstScanProgress);  // 超過 100 時限制在 100
        Assert.Equal(3, t.SkippedLines);         // 格式不對的計數當成 0
        Assert.Equal("2026-10-01", t.DataFrom);
        Assert.True(t.FormatSuspect);
        Assert.True(t.Devices.UploadCopied);
        Assert.False(t.Devices.UploadRevoked);
        Assert.Equal(["relay-self", "dev-desk"], t.Devices.Devices.Select(d => d.Id));
        Assert.True(t.Devices.Devices[0].IsSelf);
        Assert.True(t.Devices.Devices[1].Revoked);
        Assert.Null(t.Devices.Devices[1].LastUpload);
        Assert.Equal("桌機（已撤銷）", t.Devices.MenuTitle(TokenDeviceScope.Device("dev-desk"), Now));

        // 面板讀取不含每小時資料
        Assert.Empty(new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc).Tokens.Hours);
    }

    [Fact]
    public void ReadingDoesNotChangeTheDatabaseOrHoldTheFile()
    {
        Make("full");
        var before = Hash(DbPath);
        var reader = new HistoryReader(DbPath);
        Assert.Equal(HistoryReader.Status.Ready, reader.Read(Now, TimeZoneInfo.Utc, hourly: true).Status);
        Assert.Equal(before, Hash(DbPath));
        // 讀完就關閉連線：收集器（損毀時）可以改名保留、App 不會擋住
        File.Move(DbPath, DbPath + ".kept");
        File.Move(DbPath + ".kept", DbPath);
        Assert.Equal(HistoryReader.Status.Ready, reader.Read(Now, TimeZoneInfo.Utc).Status);
    }

    [Fact]
    public void ReadsCommittedDataWhileTheCollectorIsWriting()
    {
        Make("full");
        using var writer = Process.Start(Script(DbPath, "hold", Now.ToUnixTimeSeconds().ToString()))!;
        try
        {
            Assert.Equal("locked", writer.StandardOutput.ReadLine());
            var watch = Stopwatch.StartNew();
            var during = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
            watch.Stop();
            Assert.Equal(HistoryReader.Status.Ready, during.Status);
            // WAL：讀取不等寫入的交易，讀到提交前的狀態
            Assert.True(watch.ElapsedMilliseconds < HistoryReader.BusyTimeoutMs, $"讀取等了 {watch.ElapsedMilliseconds} ms");
            Assert.DoesNotContain(during.History.Samples, s => s.UsedPct == 99);
        }
        finally
        {
            writer.StandardInput.WriteLine();
            writer.StandardInput.Close();
            writer.WaitForExit();
        }
        Assert.Equal(0, writer.ExitCode);
        var after = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
        Assert.Contains(after.History.Samples, s => s.UsedPct == 99);
    }

    [Fact]
    public void OneReadSeesOneSnapshotWhenTheCollectorCommitsInBetween()
    {
        Make("full");
        var reader = new HistoryReader(DbPath) { BetweenQueries = () => Make("commit") };
        var during = reader.Read(Now, TimeZoneInfo.Utc);
        Assert.Equal(HistoryReader.Status.Ready, during.Status);
        // 收集器在額度歷史與 Token 統計之間提交（沒有被讀取擋住，Make 會檢查結束碼）：這次讀到的全是提交前的
        Assert.DoesNotContain(during.Tokens.Days, d => d.Day == "2026-10-26");
        Assert.Equal(123456, during.Tokens.Records["total_tokens"].Value);
        var after = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
        Assert.Contains(after.Tokens.Days, d => d.Day == "2026-10-26");
        Assert.Equal(128456, after.Tokens.Records["total_tokens"].Value);
    }

    [Fact]
    public void OlderSchemaIsReportedWithoutReading()
    {
        Make("old");
        var result = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
        Assert.Equal(HistoryReader.Status.OlderSchema, result.Status);
        Assert.Equal(2, result.SchemaVersion);
        Assert.False(result.CanRead);
    }

    [Fact]
    public void CorruptFileFailsWithoutDetails()
    {
        File.WriteAllText(DbPath, "這不是 SQLite 資料庫，這不是 SQLite 資料庫，這不是 SQLite 資料庫");
        var before = Hash(DbPath);
        var result = new HistoryReader(DbPath).Read(Now, TimeZoneInfo.Utc);
        Assert.Equal(HistoryReader.Status.Failed, result.Status);
        Assert.NotNull(result.Stage);
        Assert.Equal(before, Hash(DbPath));
    }

    [Fact]
    public void ChangeStampFollowsTheFiles()
    {
        var reader = new HistoryReader(DbPath);
        Assert.Equal("-|-", reader.ChangeStamp());
        Make("full");
        var stamp = reader.ChangeStamp();
        Assert.NotEqual("-|-", stamp);
        Assert.Equal(stamp, reader.ChangeStamp());
    }
}
