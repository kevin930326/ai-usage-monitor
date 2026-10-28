using Xunit;

namespace AIUsageMonitor.Core.Tests;

public class RingFloatLayoutTests
{
    // 1920×1080、工作列在下面 48 px；150%（DPI 144）
    private static readonly MonitorInfo Screen = new(@"\\.\DISPLAY1", new PixelRect(0, 0, 1920, 1080), new PixelRect(0, 0, 1920, 1032), 144, true);
    private const double Dip = 56;
    private static readonly int Size = (int)Math.Round(Dip * Screen.Scale);  // 84 px

    private static PixelRect Ring(int x, int y) => PixelRect.FromSize(x, y, Size, Size);

    [Fact]
    public void ExpandsTowardTheInnerSide()
    {
        Assert.Equal(RingExpandDirection.Left, RingFloatLayout.Direction(Ring(1500, 500), Screen, Dip));
        Assert.Equal(RingExpandDirection.Right, RingFloatLayout.Direction(Ring(300, 500), Screen, Dip));
        // 正中間（中心 x = 960）算右半邊
        Assert.Equal(RingExpandDirection.Left, RingFloatLayout.Direction(Ring(960 - Size / 2, 500), Screen, Dip));
    }

    [Fact]
    public void DockedRingsExpandDownOrUp()
    {
        var margin = (int)Math.Round(RingPlacement.SnapMargin * Screen.Scale);
        var left = Ring(margin, 300);
        var right = Ring(1920 - margin - Size, 300);
        Assert.Equal(RingDock.Left, RingFloatLayout.DockOf(left, Screen));
        Assert.Equal(RingDock.Right, RingFloatLayout.DockOf(right, Screen));
        Assert.Equal(RingDock.None, RingFloatLayout.DockOf(Ring(200, 300), Screen));
        Assert.Equal(RingExpandDirection.Down, RingFloatLayout.Direction(left, Screen, Dip));
        Assert.Equal(RingExpandDirection.Down, RingFloatLayout.Direction(right, Screen, Dip));
        // 貼在左下角：下面放不下，往上
        var bottom = Ring(margin, 1032 - margin - Size);
        Assert.Equal(RingExpandDirection.Up, RingFloatLayout.Direction(bottom, Screen, Dip));
        var up = RingFloatLayout.Expanded(bottom, RingExpandDirection.Up, Screen, Dip);
        Assert.True(Screen.WorkArea.Contains(up));
        Assert.True(up.Bottom >= bottom.Bottom - 1 && up.Top < bottom.Top);
    }

    [Fact]
    public void ExpandedStaysInsideTheWorkArea()
    {
        foreach (var (x, y) in new[] { (0, 0), (1920 - Size, 0), (0, 1032 - Size), (1920 - Size, 1032 - Size), (900, 500), (40, 2), (1700, 1000 - Size) })
        {
            var ring = Ring(x, y);
            var direction = RingFloatLayout.Direction(ring, Screen, Dip);
            var expanded = RingFloatLayout.Expanded(ring, direction, Screen, Dip);
            Assert.True(Screen.WorkArea.Contains(expanded), $"{x},{y} {direction} {expanded}");
        }
    }

    [Fact]
    public void ExpandedKeepsTheRingInPlace()
    {
        var ring = Ring(1500, 500);
        var expanded = RingFloatLayout.Expanded(ring, RingExpandDirection.Left, Screen, Dip);
        var shape = RingShape.Shape(RingExpandDirection.Left, RingDock.None, Dip).Inflate(RingShape.Inset);
        // 圓環在膠囊的右端（與膠囊的半圓同心），膠囊往左延伸
        Assert.InRange(expanded.Right - (ring.Left + Size / 2.0 + shape.Right * Screen.Scale), 0, 1);
        Assert.True(expanded.Left < ring.Left - 180 * Screen.Scale);
        Assert.Equal(ring.Top + Size / 2.0, (expanded.Top + expanded.Bottom) / 2.0, 1);
    }

    [Fact]
    public void ShapesContainTheDiscAndTheRows()
    {
        foreach (var size in new[] { 40.0, 56, 72 })
        {
            var r = RingShape.DiscRadius(size);
            foreach (var direction in Enum.GetValues<RingExpandDirection>())
            {
                foreach (var dock in new[] { RingDock.Left, RingDock.Right })
                {
                    var shape = RingShape.Shape(direction, dock, size);
                    var info = RingShape.Info(direction, dock, size);
                    Assert.True(shape.Left <= -r && shape.Right >= r && shape.Top <= -r && shape.Bottom >= r, $"{size} {direction} disc");
                    Assert.True(shape.Left <= info.Left && shape.Right >= info.Right && shape.Top <= info.Top && shape.Bottom >= info.Bottom,
                                $"{size} {direction} info");
                    Assert.Equal(RingShape.InfoWidth, info.Width, 3);
                    Assert.Equal(RingShape.RowsHeight, info.Height, 3);
                }
            }
        }
        // 貼右邊時往下展開：圓環在右上（外框往左延伸）
        var docked = RingShape.Shape(RingExpandDirection.Down, RingDock.Right, Dip);
        Assert.True(docked.Left < -100 && docked.Right < 40);
    }

    [Fact]
    public void ShiftMovesTheContentWithTheClampedWindow()
    {
        // 100%、小圓環（40 DIP）貼在上緣：膠囊（高 80）比圓環高，視窗被推下來，內容也要跟著往下移
        var plain = new MonitorInfo(@"\\.\DISPLAY1", new PixelRect(0, 0, 1920, 1080), new PixelRect(0, 0, 1920, 1040), 96, true);
        foreach (var size in new[] { 40, 56, 72 })
        {
            foreach (var y in new[] { 8, 1040 - 8 - size })
            {
                var ring = PixelRect.FromSize(900, y, size, size);
                var direction = RingFloatLayout.Direction(ring, plain, size);
                var window = RingFloatLayout.Expanded(ring, direction, plain, size);
                var (dx, dy) = RingFloatLayout.ExpandedShift(ring, direction, plain, size);
                var shape = RingShape.Shape(direction, RingFloatLayout.DockOf(ring, plain), size).Inflate(RingShape.Inset);
                var info = RingShape.Info(direction, RingFloatLayout.DockOf(ring, plain), size);
                var cx = ring.Left + size / 2.0 + dx;
                var cy = ring.Top + size / 2.0 + dy;
                Assert.True(plain.WorkArea.Contains(window));
                // 移動後的外框與兩行資訊都在視窗裡
                Assert.InRange(cy + shape.Top, window.Top - 1, window.Top + 1);
                Assert.True(cy + info.Top >= window.Top && cy + info.Bottom <= window.Bottom, $"{size} {y}");
                Assert.True(cx + info.Left >= window.Left && cx + info.Right <= window.Right, $"{size} {y}");
            }
        }
        // 不必推的時候不動
        Assert.Equal((0, 0), RingFloatLayout.ExpandedShift(Ring(1500, 500), RingExpandDirection.Left, Screen, Dip));
    }

    [Fact]
    public void TabShowsHalfTheRingAtTheEdge()
    {
        var margin = (int)Math.Round(RingPlacement.SnapMargin * Screen.Scale);
        var left = RingFloatLayout.Tab(Ring(margin, 300), RingDock.Left, Screen);
        Assert.Equal(new PixelRect(0, 300, Size / 2, 300 + Size), left);
        var right = RingFloatLayout.Tab(Ring(1920 - margin - Size, 300), RingDock.Right, Screen);
        Assert.Equal(new PixelRect(1920 - Size / 2, 300, 1920, 300 + Size), right);
        Assert.Equal(Ring(10, 10), RingFloatLayout.Tab(Ring(10, 10), RingDock.None, Screen));
    }

    [Fact]
    public void SecondMonitorUsesItsOwnWorkArea()
    {
        // 主螢幕右邊的 100% 螢幕：貼在它的左邊緣（與主螢幕相接處）
        var second = new MonitorInfo(@"\\.\DISPLAY2", new PixelRect(1920, 0, 3840, 1080), new PixelRect(1920, 0, 3840, 1080), 96);
        var ring = PixelRect.FromSize(1928, 400, 56, 56);
        Assert.Equal(RingDock.Left, RingFloatLayout.DockOf(ring, second));
        Assert.Equal(new PixelRect(1920, 400, 1948, 456), RingFloatLayout.Tab(ring, RingDock.Left, second));
        var expanded = RingFloatLayout.Expanded(ring, RingFloatLayout.Direction(ring, second, 56), second, 56);
        Assert.True(second.WorkArea.Contains(expanded));
    }
}

public class RingDetailsTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-26T09:30:00Z");

    private static UsageSnapshot Snapshot(string providers, string updated = "2026-10-26T09:25:00Z") =>
        UsageDecoder.Decode("{\"schema_version\": 1, \"updated_at\": \"" + updated + "\", \"providers\": {" + providers + "}}");

    private const string Claude = """
        "claude": {"plan": "Max", "windows": [
          {"id": "five_hour", "label": "5 小時", "used_pct": 27, "resets_at": "2026-10-26T12:42:00Z"},
          {"id": "weekly", "label": "每週", "used_pct": 37, "resets_at": "2026-10-30T11:30:00Z"}]}
        """;
    private const string Codex = """
        "codex": {"plan": "Plus", "windows": [
          {"id": "five_hour", "label": "5 小時", "used_pct": 10, "resets_at": "2026-10-26T13:36:00Z"},
          {"id": "weekly", "label": "每週", "used_pct": 22, "resets_at": "2026-10-31T15:30:00Z"}]}
        """;

    [Fact]
    public void LeastRemainingThenTheOtherServicesTightest()
    {
        var d = RingDetails.From(Snapshot(Claude + "," + Codex), WindowChoice.Automatic, Now);
        Assert.Equal(2, d.Rows.Count);
        Assert.Equal(("claude", "Claude 每週", 63), (d.Rows[0].Provider, d.Rows[0].Name, d.Rows[0].RemainingPct));
        Assert.Equal(("codex", "Codex 每週", 78), (d.Rows[1].Provider, d.Rows[1].Name, d.Rows[1].RemainingPct));
        Assert.Equal("4天 2小時後重置", d.Rows[0].Countdown);
        Assert.Equal(0.63, d.Rows[0].Fraction, 6);
    }

    [Fact]
    public void ChosenWindowFirst()
    {
        var d = RingDetails.From(Snapshot(Claude + "," + Codex), WindowChoice.Parse("codex/five_hour"), Now);
        Assert.Equal(("codex", "Codex 5 小時"), (d.Rows[0].Provider, d.Rows[0].Name));
        Assert.Equal(("claude", "Claude 每週"), (d.Rows[1].Provider, d.Rows[1].Name));
    }

    [Fact]
    public void SingleServiceShowsItsOtherWindow()
    {
        var d = RingDetails.From(Snapshot(Claude), WindowChoice.Automatic, Now);
        Assert.Equal(["Claude 每週", "Claude 5 小時"], d.Rows.Select(r => r.Name));
    }

    [Fact]
    public void ErroredServiceIsSkipped()
    {
        var d = RingDetails.From(Snapshot(Claude + """, "codex": {"plan": null, "error": "x", "windows": []}"""), WindowChoice.Automatic, Now);
        Assert.Equal(["Claude 每週", "Claude 5 小時"], d.Rows.Select(r => r.Name));
    }

    [Fact]
    public void StaleAndEmpty()
    {
        var d = RingDetails.From(Snapshot(Claude + "," + Codex, "2026-10-26T08:00:00Z"), WindowChoice.Automatic, Now);
        Assert.All(d.Rows, r => Assert.Equal(RingState.Stale, r.State));
        Assert.Same(RingDetails.Empty, RingDetails.From(null, WindowChoice.Automatic, Now));
        Assert.Same(RingDetails.Empty, RingDetails.From(Snapshot(""), WindowChoice.Automatic, Now));
    }

    [Fact]
    public void EqualWhenNothingChanged()
    {
        var s = Snapshot(Claude + "," + Codex);
        Assert.Equal(RingDetails.From(s, WindowChoice.Automatic, Now), RingDetails.From(s, WindowChoice.Automatic, Now.AddSeconds(-20)));
        Assert.NotEqual(RingDetails.From(s, WindowChoice.Automatic, Now), RingDetails.From(s, WindowChoice.Automatic, Now.AddMinutes(61)));
    }
}

public class RingSettingsTests
{
    [Fact]
    public void DockAndTicksDefaultsAndRoundTrip()
    {
        var s = AppSettings.Parse(null);
        Assert.True(s.DockToEdge);
        Assert.False(s.RingTicks);
        s.DockToEdge = false;
        s.RingTicks = true;
        var back = AppSettings.Parse(s.Serialize());
        Assert.False(back.DockToEdge);
        Assert.True(back.RingTicks);
    }
}
