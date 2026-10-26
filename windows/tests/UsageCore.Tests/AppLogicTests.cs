using Xunit;

namespace AIUsageMonitor.Core.Tests;

public class CollectorKickThrottleTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_793_007_000);

    [Fact]
    public void SixtySecondsBetweenKicks()
    {
        var t = new CollectorKickThrottle();
        Assert.Equal(CollectorKickThrottle.Decision.Kick, t.DecisionAt(T0));
        t.Record(T0);
        Assert.Equal(CollectorKickThrottle.Decision.TooSoon, t.DecisionAt(T0.AddSeconds(59)));
        Assert.Equal(CollectorKickThrottle.Decision.Kick, t.DecisionAt(T0.AddSeconds(60)));
    }

    [Fact]
    public void ClockGoingBackIsTooSoon()
    {
        var t = new CollectorKickThrottle([T0]);
        Assert.Equal(CollectorKickThrottle.Decision.TooSoon, t.DecisionAt(T0.AddHours(-1)));
    }

    [Fact]
    public void HundredPerDay()
    {
        var t = new CollectorKickThrottle();
        for (var i = 0; i < 100; i++) t.Record(T0.AddMinutes(2 * i));
        var after = T0.AddMinutes(2 * 99 + 5);
        Assert.Equal(CollectorKickThrottle.Decision.DailyLimitReached, t.DecisionAt(after));
        // 最早的一筆滿 24 小時後又可以
        Assert.Equal(CollectorKickThrottle.Decision.Kick, t.DecisionAt(T0.AddHours(24)));
        t.Record(T0.AddHours(24));
        Assert.Equal(100, t.Kicks.Count);
    }
}

public class RingContentTests
{
    private static UsageSnapshot Snapshot(string updated, double used, string resets) => UsageDecoder.Decode("""
        {"schema_version": 1, "updated_at": "UPDATED", "providers": {
          "claude": {"plan": "Max", "windows": [{"id": "weekly", "label": "每週", "used_pct": USED, "resets_at": "RESETS"}]}}}
        """.Replace("UPDATED", updated).Replace("USED", used.ToString(System.Globalization.CultureInfo.InvariantCulture)).Replace("RESETS", resets));

    [Fact]
    public void TooltipAndQuantizedTime()
    {
        var now = DateTimeOffset.Parse("2026-10-26T09:30:00Z");
        var content = RingContent.From(Snapshot("2026-10-26T09:25:00Z", 37, "2026-10-30T11:30:00Z"), WindowChoice.Automatic, now);
        Assert.Equal("claude", content.Provider);
        Assert.Equal(63, content.RemainingPct);
        // 剩 4 天 2 小時 / 7 天 = 0.583 → 以 2% 為單位
        Assert.Equal(58, content.TimeRemaining);
        Assert.Equal(RingState.Normal, content.State);
        Assert.Equal("Claude 每週 剩 63% · 4天 2小時後重置", content.Tooltip);
        Assert.Equal("剩餘最少的額度：Claude 每週，剩 63%", content.AccessibilityText);
    }

    [Fact]
    public void StaleAndEmpty()
    {
        var now = DateTimeOffset.Parse("2026-10-26T09:30:00Z");
        var stale = RingContent.From(Snapshot("2026-10-26T08:00:00Z", 37, "2026-10-30T11:30:00Z"), WindowChoice.Automatic, now);
        Assert.Equal(RingState.Stale, stale.State);
        Assert.EndsWith("· 資料已過期", stale.Tooltip);
        Assert.Same(RingContent.Empty, RingContent.From(null, WindowChoice.Automatic, now));
    }

    [Fact]
    public void SameContentIsEqual()
    {
        // 一分鐘後內容相同（2% 的內圈沒有跨格）就不重畫
        var s = Snapshot("2026-10-26T09:25:00Z", 37, "2026-10-30T11:30:00Z");
        var a = RingContent.From(s, WindowChoice.Automatic, DateTimeOffset.Parse("2026-10-26T09:30:00Z"));
        var b = RingContent.From(s, WindowChoice.Automatic, DateTimeOffset.Parse("2026-10-26T09:31:00Z"));
        Assert.Equal(a with { Tooltip = "" }, b with { Tooltip = "" });
    }
}

public class RingPlacementTests
{
    // 1920×1080，工作列在下方 48px；DPI 144（150%）
    private static readonly MonitorInfo Primary = new(@"\\.\DISPLAY1", new(0, 0, 1920, 1080), new(0, 0, 1920, 1032), 144, true);
    private static readonly MonitorInfo Right = new(@"\\.\DISPLAY2", new(1920, 0, 4480, 1440), new(1920, 0, 4480, 1440), 96);

    [Fact]
    public void SnapsToNearEdgesWithMargin()
    {
        var ring = PixelRect.FromSize(1920 - 84 - 20, 1032 - 84 - 10, 84, 84);
        var snapped = RingPlacement.Snap(ring, Primary);
        // 16 DIP × 1.5 = 24px 內 → 吸過去，留 8 DIP × 1.5 = 12px
        Assert.Equal(PixelRect.FromSize(1920 - 12 - 84, 1032 - 12 - 84, 84, 84), snapped);
    }

    [Fact]
    public void FarFromEdgesStaysAndOffscreenIsClamped()
    {
        var middle = PixelRect.FromSize(800, 400, 84, 84);
        Assert.Equal(middle, RingPlacement.Snap(middle, Primary));
        var outside = PixelRect.FromSize(-500, 2000, 84, 84);
        var clamped = RingPlacement.Clamp(outside, Primary.WorkArea);
        Assert.True(Primary.WorkArea.Contains(clamped));
    }

    [Fact]
    public void RestoresPerMonitorThenScalesThenDefaults()
    {
        var saved = RingPlacement.Remember([], PixelRect.FromSize(2000, 100, 56, 56), Right, DateTimeOffset.FromUnixTimeSeconds(10));
        var (rect, monitor) = RingPlacement.Restore(saved, [Primary, Right], m => (int)(56 * m.Scale));
        Assert.Equal(Right, monitor);
        Assert.Equal(PixelRect.FromSize(2000, 100, 56, 56), rect);

        // 解析度改變：同裝置依比例換算
        var smaller = Right with { Bounds = new(1920, 0, 3200, 720), WorkArea = new(1920, 0, 3200, 720) };
        (rect, monitor) = RingPlacement.Restore(saved, [Primary, smaller], m => (int)(56 * m.Scale));
        Assert.Equal(smaller, monitor);
        Assert.Equal(PixelRect.FromSize(1920 + 40, 50, 56, 56), rect);

        // 螢幕拔掉：主螢幕右下角內縮 24 DIP
        (rect, monitor) = RingPlacement.Restore(saved, [Primary], m => (int)(56 * m.Scale));
        Assert.Equal(Primary, monitor);
        Assert.Equal(PixelRect.FromSize(1920 - 36 - 84, 1032 - 36 - 84, 84, 84), rect);
    }

    [Fact]
    public void RemembersAtMostSixteen()
    {
        var list = new List<SavedPosition>();
        for (var i = 0; i < 20; i++)
        {
            var m = Primary with { Device = $@"\\.\DISPLAY{i}" };
            list = RingPlacement.Remember(list, PixelRect.FromSize(10, 10, 56, 56), m, DateTimeOffset.FromUnixTimeSeconds(i));
        }
        Assert.Equal(16, list.Count);
        Assert.DoesNotContain(list, p => p.Key.StartsWith(@"\\.\DISPLAY3|", StringComparison.Ordinal));
        Assert.Contains(list, p => p.Key.StartsWith(@"\\.\DISPLAY19|", StringComparison.Ordinal));
    }

    [Fact]
    public void MonitorOfUsesLargestOverlap()
    {
        Assert.Equal(Right, RingPlacement.MonitorOf(PixelRect.FromSize(1900, 10, 56, 56), [Primary, Right]));
        Assert.Equal(Primary, RingPlacement.MonitorOf(PixelRect.FromSize(-900, -900, 56, 56), [Primary, Right]));
    }
}

public class PanelPlacementTests
{
    private static readonly MonitorInfo M = new(@"\\.\DISPLAY1", new(0, 0, 1920, 1080), new(0, 0, 1920, 1032), 96, true);

    [Fact]
    public void RingAtBottomRightPutsPanelToTheLeftAlignedToTheBottom()
    {
        var ring = PixelRect.FromSize(1920 - 8 - 56, 1032 - 8 - 56, 56, 56);
        var panel = PanelPlacement.NextToRing(ring, 360, 500, M);
        Assert.Equal(PixelRect.FromSize(ring.Left - 8 - 360, ring.Bottom - 500, 360, 500), panel);
    }

    [Fact]
    public void RingAtTopLeftPutsPanelToTheRight()
    {
        var ring = PixelRect.FromSize(8, 8, 56, 56);
        Assert.Equal(PixelRect.FromSize(8 + 56 + 8, 8, 360, 500), PanelPlacement.NextToRing(ring, 360, 500, M));
    }

    [Fact]
    public void FallsBackInsideTheWorkArea()
    {
        var ring = PixelRect.FromSize(800, 400, 56, 56);
        var panel = PanelPlacement.NextToRing(ring, 1800, 1000, M);
        Assert.True(M.WorkArea.Contains(panel));
    }

    [Fact]
    public void TrayCornerFollowsTheCursor()
    {
        Assert.Equal(PixelRect.FromSize(1920 - 12 - 360, 1032 - 12 - 500, 360, 500), PanelPlacement.NearTray(1800, 1060, 360, 500, M));
        var topTaskbar = M with { WorkArea = new(0, 48, 1920, 1080) };
        Assert.Equal(PixelRect.FromSize(1920 - 12 - 360, 48 + 12, 360, 500), PanelPlacement.NearTray(1800, 20, 360, 500, topTaskbar));
    }
}

public class FullscreenRuleTests
{
    private static readonly MonitorInfo A = new(@"\\.\DISPLAY1", new(0, 0, 1920, 1080), new(0, 0, 1920, 1032), 96, true);
    private static readonly MonitorInfo B = new(@"\\.\DISPLAY2", new(1920, 0, 3840, 1080), new(1920, 0, 3840, 1080), 96);

    [Fact]
    public void CoveringTheRingMonitorIsFullscreen()
    {
        Assert.True(FullscreenRule.IsFullscreen("Chrome_WidgetWin_1", false, new(0, 0, 1920, 1080), A, A));
        // 最大化（只涵蓋工作區）不是全螢幕
        Assert.False(FullscreenRule.IsFullscreen("Chrome_WidgetWin_1", false, new(0, 0, 1920, 1032), A, A));
    }

    [Fact]
    public void OtherMonitorShellAndCloakedAreIgnored()
    {
        Assert.False(FullscreenRule.IsFullscreen("Chrome_WidgetWin_1", false, B.Bounds, B, A));
        Assert.False(FullscreenRule.IsFullscreen("WorkerW", false, A.Bounds, A, A));
        Assert.False(FullscreenRule.IsFullscreen("Progman", false, A.Bounds, A, A));
        Assert.False(FullscreenRule.IsFullscreen("ApplicationFrameWindow", true, A.Bounds, A, A));
        // 工作列自動隱藏時，最大化的記事本也涵蓋整個螢幕
        Assert.False(FullscreenRule.IsFullscreen("Notepad", false, A.Bounds, A, A, maximizedWithCaption: true));
    }

    [Fact]
    public void NotificationStates()
    {
        Assert.True(FullscreenRule.IsExclusiveFullscreen(3));
        Assert.True(FullscreenRule.IsExclusiveFullscreen(4));
        Assert.False(FullscreenRule.IsExclusiveFullscreen(2));  // QUNS_BUSY：全系統，不用
        Assert.False(FullscreenRule.IsExclusiveFullscreen(5));
    }
}

public class AppSettingsTests
{
    [Fact]
    public void DefaultsWhenMissingOrBroken()
    {
        foreach (var json in new[] { null, "", "{", "[]", "{\"display_mode\": 3, \"opacity\": \"x\"}" })
        {
            var s = AppSettings.Parse(json);
            Assert.Equal(DisplayMode.Both, s.DisplayMode);
            Assert.True(s.RingWindow.IsAutomatic);
            Assert.Equal(1, s.Opacity);
            Assert.True(s.HideInFullscreen);
            Assert.True(s.LaunchAtLogin);
        }
    }

    [Fact]
    public void RoundTripKeepsUnknownFields()
    {
        var s = AppSettings.Parse("""
            {"schema": 1, "display_mode": "tray", "ring_window": "codex/weekly", "ring_size": "large", "opacity": 0.1,
             "appearance": "dark", "launch_at_login": false, "positions": [{"key": "k", "x": 5, "y": 6, "used": 7}],
             "collector_kicks": [1793007000], "future_setting": {"a": 1}}
            """);
        Assert.Equal(DisplayMode.Tray, s.DisplayMode);
        Assert.Equal("codex/weekly", s.RingWindow.RawValue);
        Assert.Equal(RingSize.Large, s.RingSize);
        Assert.Equal(AppSettings.MinimumOpacity, s.Opacity);  // 夾到 30%
        Assert.Equal(Appearance.Dark, s.Appearance);
        Assert.False(s.LaunchAtLogin);
        Assert.Single(s.Positions);
        Assert.Single(s.CollectorKicks);
        var again = AppSettings.Parse(s.Serialize());
        Assert.Equal(s.Serialize(), again.Serialize());
        Assert.Contains("future_setting", again.Serialize());
        Assert.False(s.ShowsRing);
        Assert.True(s.ShowsTray);
    }

    [Fact]
    public void NumericEnumNamesAreRejected()
    {
        Assert.Equal(DisplayMode.Both, AppSettings.Parse("{\"display_mode\": \"2\"}").DisplayMode);
    }
}

public class IsoParsingTests
{
    [Fact]
    public void RequiresATimeZoneLikeSwift()
    {
        Assert.True(UsageDecoder.TryParseIso("2026-10-26T09:30:00Z", out var utc));
        Assert.True(UsageDecoder.TryParseIso("2026-10-26T17:30:00+08:00", out var taipei));
        Assert.Equal(utc, taipei);
        Assert.False(UsageDecoder.TryParseIso("2026-10-26T09:30:00", out _));
        Assert.False(UsageDecoder.TryParseIso("2026-10-26", out _));
    }
}
