using Xunit;

namespace AIUsageMonitor.Core.Tests;

public class MascotSettingsTests
{
    [Fact]
    public void DefaultsToTheMascotWithFirstIntro()
    {
        var s = AppSettings.Parse(null);
        Assert.Equal(RingStyle.Mascot, s.RingStyle);
        Assert.Equal("claude", s.MascotProvider);
        Assert.Null(s.MascotLook);
        Assert.Equal(MascotIntroChoice.FirstOnly, s.MascotIntro);
        Assert.Equal(MascotMotionLevel.Full, s.MascotMotion);
        Assert.True(s.MascotFollowPointer);
        Assert.Equal(20, s.MascotSleepMinutes);
        Assert.False(s.MascotSleepChosen);
        Assert.True(s.MascotWaitingPulse);
        Assert.Null(s.MascotQuietUntil);
    }

    [Fact]
    public void RoundTripsAndRejectsBadValues()
    {
        var s = AppSettings.Parse("""
            {"ring_style": "mascotpercent", "mascot_provider": "codex", "mascot_look": "X8", "mascot_intro": "off",
             "mascot_motion": "simple", "mascot_follow_pointer": false, "mascot_sleep_minutes": 15, "mascot_sleep_chosen": true, "mascot_waiting_pulse": false,
             "mascot_quiet_until": 1793007000}
            """);
        Assert.Equal(RingStyle.MascotPercent, s.RingStyle);
        Assert.Equal("codex", s.MascotProvider);
        Assert.Equal("X8", s.MascotLook);
        Assert.Equal(MascotIntroChoice.Off, s.MascotIntro);
        Assert.Equal(MascotMotionLevel.Simple, s.MascotMotion);
        Assert.False(s.MascotFollowPointer);
        Assert.Equal(15, s.MascotSleepMinutes);
        Assert.False(s.MascotWaitingPulse);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1793007000), s.MascotQuietUntil);
        Assert.Equal(s.Serialize(), AppSettings.Parse(s.Serialize()).Serialize());

        var bad = AppSettings.Parse("""{"mascot_provider": "gemini", "mascot_sleep_minutes": 7, "mascot_sleep_chosen": true, "mascot_look": "", "ring_style": "1"}""");
        Assert.Equal("claude", bad.MascotProvider);
        Assert.Equal(20, bad.MascotSleepMinutes);
        Assert.Null(bad.MascotLook);
        Assert.Equal(RingStyle.Mascot, bad.RingStyle);
    }

    [Fact]
    public void SleepDefaultMovesTo20UnlessTheUserChose()
    {
        // 舊版不分選過與否都寫（當時的預設是 5）：沒有標記時 5 改用新的預設，其他值是使用者選的
        Assert.Equal(20, AppSettings.Parse("""{"mascot_sleep_minutes": 5}""").MascotSleepMinutes);
        Assert.Equal(10, AppSettings.Parse("""{"mascot_sleep_minutes": 10}""").MascotSleepMinutes);
        Assert.Equal(5, AppSettings.Parse("""{"mascot_sleep_minutes": 5, "mascot_sleep_chosen": true}""").MascotSleepMinutes);
        var chosen = AppSettings.Parse("""{"mascot_sleep_minutes": 3, "mascot_sleep_chosen": true}""");
        Assert.Equal(3, AppSettings.Parse(chosen.Serialize()).MascotSleepMinutes);
    }

    [Fact]
    public void QuietOnlyUntilTheTime()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var s = new AppSettings { MascotQuietUntil = now.AddMinutes(5) };
        Assert.True(s.IsMascotQuiet(now));
        Assert.False(s.IsMascotQuiet(now.AddMinutes(6)));
    }

    [Fact]
    public void MotionLevelsMatchTheMac()
    {
        Assert.Equal(MascotMotionLevel.Simple, MascotMotion.Effective(MascotMotionLevel.Full, animationsEnabled: false));
        Assert.Equal(MascotMotionLevel.Off, MascotMotion.Effective(MascotMotionLevel.Off, animationsEnabled: false));
        Assert.Equal(MascotMotionLevel.Full, MascotMotion.Effective(MascotMotionLevel.Full, animationsEnabled: true));
        Assert.True(MascotMotionLevel.Simple.MovesEyes());
        Assert.False(MascotMotionLevel.Simple.AnimatesBody());
        Assert.False(MascotMotionLevel.Off.MovesEyes());
        Assert.True(MascotMotion.ShouldPlayIntro(MascotIntroChoice.FirstOnly, MascotMotionLevel.Full, playedBefore: false));
        Assert.False(MascotMotion.ShouldPlayIntro(MascotIntroChoice.FirstOnly, MascotMotionLevel.Full, playedBefore: true));
        Assert.True(MascotMotion.ShouldPlayIntro(MascotIntroChoice.Every, MascotMotionLevel.Full, playedBefore: true));
        Assert.False(MascotMotion.ShouldPlayIntro(MascotIntroChoice.Every, MascotMotionLevel.Simple, playedBefore: false));
        Assert.False(MascotMotion.ShouldPlayIntro(MascotIntroChoice.Off, MascotMotionLevel.Full, playedBefore: false));
    }
}

public class MascotActivityTests
{
    private sealed class FakeLister(Dictionary<string, List<MascotDirectoryEntry>> tree) : IMascotDirectoryLister
    {
        public List<string> Listed { get; } = [];

        public IReadOnlyList<MascotDirectoryEntry> Entries(string directory)
        {
            Listed.Add(directory);
            return tree.GetValueOrDefault(directory) ?? [];
        }
    }

    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    [Fact]
    public void RecentJsonlMeansWorking()
    {
        var lister = new FakeLister(new()
        {
            ["/c/projects"] = [new("/c/projects/a", true, Now.AddMinutes(-1)), new("/c/projects/b", true, Now.AddHours(-1))],
            ["/c/projects/a"] = [new("/c/projects/a/s.jsonl", false, Now.AddSeconds(-10)), new("/c/projects/a/x.txt", false, Now)],
        });
        var probe = new MascotActivityProbe([new("/c/projects", 2)], lister);
        Assert.True(probe.IsWorking(Now));
        Assert.False(probe.IsWorking(Now.AddMinutes(2)));
        Assert.True(probe.IsActive(5 * 60, Now.AddMinutes(2)));
    }

    [Fact]
    public void CodexLooksOnlyAtTheNewestDays()
    {
        var lister = new FakeLister(new()
        {
            ["/x/sessions"] = [new("/x/sessions/2026", true, Now)],
            ["/x/sessions/2026"] = [new("/x/sessions/2026/09", true, Now), new("/x/sessions/2026/10", true, Now), new("/x/sessions/2026/08", true, Now)],
            ["/x/sessions/2026/08"] = [new("/x/sessions/2026/08/01", true, Now)],
            ["/x/sessions/2026/08/01"] = [new("/x/sessions/2026/08/01/r.jsonl", false, Now)],
        });
        var probe = new MascotActivityProbe([new("/x/sessions", 4, 2)], lister);
        // 08 不是最新的兩個（09、10）：不看
        Assert.False(probe.IsWorking(Now));
        Assert.DoesNotContain("/x/sessions/2026/08", lister.Listed);
    }

    [Fact]
    public void DefaultRootsFollowTheCollectorRules()
    {
        var claude = MascotActivityProbe.DefaultRoot(AgentKind.Claude, null, _ => null, "/home/u");
        Assert.Equal(Path.Combine("/home/u", ".claude", "projects"), claude.Path);
        var codex = MascotActivityProbe.DefaultRoot(AgentKind.Codex, """{"codex_home": "/data/codex"}"""u8.ToArray(), _ => null, "/home/u");
        Assert.Equal(Path.Combine("/data/codex", "sessions"), codex.Path);
        Assert.Equal(2, codex.NewestByName);
    }

    [Fact]
    public void RealListerReadsOnlyNamesAndTimes()
    {
        var dir = Directory.CreateTempSubdirectory("aum-activity-");
        try
        {
            File.WriteAllText(Path.Combine(dir.FullName, "s.jsonl"), "{}");
            var probe = new MascotActivityProbe([new(dir.FullName, 1)]);
            Assert.True(probe.IsWorking(DateTimeOffset.UtcNow));
            Assert.False(new MascotActivityProbe([new(Path.Combine(dir.FullName, "missing"), 2)]).IsWorking(DateTimeOffset.UtcNow));
        }
        finally
        {
            dir.Delete(true);
        }
    }
}
