using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>Windows 自己的文字（「這台電腦」）與 golden 沒有涵蓋的小函式。計算規則以 golden 比對（LogicGoldenTests）。</summary>
public class TokenDevicesTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_793_007_000);

    private static readonly TokenDevices Devices = new([
        new TokenDevice("self", "PC", Now.AddMinutes(-5), IsSelf: true),
        new TokenDevice("mac", "MacBook", Now.AddHours(-3)),
    ]);

    [Fact]
    public void TitlesSayThisComputer()
    {
        Assert.Equal("這台電腦", Devices.Title(TokenDeviceScope.ThisComputer));
        Assert.Equal("所有電腦（2 台）", Devices.Title(TokenDeviceScope.All));
        Assert.Equal("MacBook", Devices.Title(TokenDeviceScope.Device("mac")));
        Assert.Equal("其他電腦", Devices.Title(TokenDeviceScope.Device("gone")));
        Assert.Equal("這台電腦還沒有 Claude Code 或 Codex CLI 的紀錄", Devices.EmptyText(TokenDeviceScope.ThisComputer));
        Assert.Equal("「MacBook」還沒有上傳 Token 統計", Devices.EmptyText(TokenDeviceScope.Device("mac")));
        Assert.DoesNotContain("Mac", TokenDevices.ThisComputerHelp);
    }

    [Fact]
    public void HelpListsEveryComputer()
    {
        Assert.Equal("包含已安裝收集器的電腦：這台電腦（剛剛上傳）、MacBook（3 小時前上傳）。其他電腦的數字是它們最後一次上傳的每日加總。"
                     + "不包含 claude.ai 網頁、手機 App 與雲端 session。額度 % 是整個帳號的數字。", Devices.Help(TokenDeviceScope.All, Now));
        Assert.StartsWith("只包含「MacBook」上傳的每日 Token（3 小時前上傳）。", Devices.Help(TokenDeviceScope.Device("mac"), Now));
        Assert.Equal(TokenDevices.ThisComputerHelp, Devices.Help(TokenDeviceScope.Device("gone"), Now));
    }

    [Theory]
    [InlineData("this", "this")]
    [InlineData("all", "all")]
    [InlineData("device:abc", "device:abc")]
    [InlineData("device:", null)]
    [InlineData("other", null)]
    [InlineData(null, null)]
    public void ScopeRawValueRoundTrips(string? raw, string? expected) => Assert.Equal(expected, TokenDeviceScope.Parse(raw)?.RawValue);

    [Fact]
    public void WithoutOtherComputersOnlyThisComputer()
    {
        var none = new TokenDevices([new TokenDevice("self", "PC", IsSelf: true)]);
        Assert.False(none.Enabled);
        Assert.Equal([TokenDeviceScope.ThisComputer], none.Scopes);
        Assert.Equal(TokenDeviceScope.ThisComputer, none.Resolve(TokenDeviceScope.All));
        Assert.Equal(TokenDevices.None, new TokenDevices([]));
    }

    [Theory]
    [InlineData("2026-10-26", "2026-10-26")]
    [InlineData("2026-2-30", "2026-03-02")]
    [InlineData("2026--10-26", "2026-10-26")]
    [InlineData("2026-10", null)]
    [InlineData("abc", null)]
    public void ParsesCollectorDayKeysLikeSwift(string key, string? expected) =>
        Assert.Equal(expected, LocalCalendar.ParseKey(key) is { } d ? LocalCalendar.Key(d) : null);

    [Fact]
    public void DayPartUsesTheLocalTimeZone()
    {
        var taipei = TimeZoneInfo.FindSystemTimeZoneById("Asia/Taipei");
        // 2026-10-26T09:30Z = 台北週一 17:30
        Assert.Equal("週一下午", WeeklyForecast.DayPart(Now, taipei));
        Assert.Equal("週一早上", WeeklyForecast.DayPart(Now, TimeZoneInfo.Utc));
        Assert.Equal("週二凌晨", WeeklyForecast.DayPart(Now.AddHours(15), TimeZoneInfo.Utc));
        Assert.Equal("週一晚上", WeeklyForecast.DayPart(Now.AddHours(9), TimeZoneInfo.Utc));
    }

    [Fact]
    public void DurationText()
    {
        Assert.Equal("30 秒", TokenFormat.Duration(30));
        Assert.Equal("1 小時 23 分", TokenFormat.Duration(83 * 60 + 5));
    }
}
