using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// usage.json 的選填事故（ADR-0018 第 4 節）：讀 fixtures/usage-forecast-incidents.json（Swift、中繼與收集器的測試讀同一份）。
/// Windows App 與 iPhone 一樣用快照裡收集器算好的 <c>forecast</c>（<c>QuotaForecast.Current</c>），不自己算。
/// </summary>
public class IncidentTests
{
    private static UsageSnapshot Load(string name) =>
        UsageDecoder.Decode(File.ReadAllText(Path.Combine(LogicGoldenTests.RepoRoot, "fixtures", name)));

    [Fact]
    public void DecodesIncidents()
    {
        var data = Load("usage-forecast-incidents.json");
        var incident = Assert.Single(data.Providers["claude"].Incidents!);
        Assert.Equal(new ServiceIncident("Elevated errors on Claude Code", "major", "https://status.claude.com/incidents/abc123",
                                         DateTimeOffset.Parse("2026-10-21T02:40:00Z")), incident);
        Assert.True(incident.IsDisruption);
        Assert.Empty(data.Providers["codex"].Incidents!);
        Assert.Null(Load("usage-sample.json").Providers["claude"].Incidents);
    }

    [Theory]
    [InlineData("\"down\"")]
    [InlineData("[{\"name\":\"x\"}]")]
    [InlineData("[{\"name\":\"x\",\"impact\":\"minor\",\"started_at\":\"yesterday\"}]")]
    [InlineData("[{\"name\":\"x\",\"impact\":\"minor\",\"url\":3}]")]
    public void BadIncidentsAreIgnored(string incidents)
    {
        var json = "{\"schema_version\":1,\"updated_at\":\"2026-10-21T03:00:00Z\",\"providers\":{\"claude\":{\"plan\":null,"
                   + "\"error\":null,\"windows\":[],\"incidents\":" + incidents + "}}}";
        Assert.Null(UsageDecoder.Decode(json).Providers["claude"].Incidents);
    }

    [Fact]
    public void SnapshotForecastAndText()
    {
        var data = Load("usage-forecast-incidents.json");
        var weekly = data.Providers["claude"].Windows[1];
        var now = data.UpdatedAt;
        Assert.Equal(new QuotaForecast(DateTimeOffset.Parse("2026-10-22T09:30:00Z"), false, null), weekly.Forecast);
        Assert.Equal(2.1, data.Providers["claude"].Windows[0].Forecast?.Faster);
        Assert.Null(data.Providers["codex"].Windows[0].Forecast);
        // 緊急與否照現在重算；過期、已經過了的不用
        Assert.True(QuotaForecast.Current(weekly, false, now.AddHours(30))?.Urgent);
        Assert.False(QuotaForecast.Current(weekly, false, now)?.Urgent);
        Assert.Null(QuotaForecast.Current(weekly, true, now));
        Assert.Null(QuotaForecast.Current(weekly, false, now.AddHours(31)));

        // 同 Swift 的 ForecastGoldenTests.text：台北時間週三 12:00
        var taipei = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
        var noon = DateTimeOffset.Parse("2026-10-28T04:00:00Z");
        string Line(double hours, double? faster = null) => new QuotaForecast(noon.AddHours(hours), false, faster).Line(noon, taipei);
        Assert.Equal("照目前速度約 14:30 用完", Line(2.5));
        Assert.Equal("照目前速度約明天 00:30 用完・比平常快 2.1 倍", Line(12.5, 2.1));
        Assert.Equal("照目前速度約週五 12:00 用完", Line(48));
        Assert.Equal("約明天 00:30 用完・快 2.1 倍", new QuotaForecast(noon.AddHours(12.5), false, 2.1).ShortLine(noon, taipei));
        Assert.Equal("照目前速度約 12:30 用完，不到 1 小時", new QuotaForecast(noon.AddHours(0.5), true, null).SpokenLine(noon, taipei));
        Assert.Equal("照目前速度約 14:30 用完", new QuotaForecast(noon.AddHours(2.5), false, null).SpokenLine(noon, taipei));
    }

    [Fact]
    public void RingReadsForecastAndIncident()
    {
        var data = Load("usage-forecast-incidents.json");
        var text = RingContent.From(data, new WindowChoice("claude", "five_hour"), data.UpdatedAt).AccessibilityText;
        Assert.Contains("照目前速度約", text);
        Assert.Contains("服務異常：", text);
    }

    [Fact]
    public void BadForecastIsIgnored()
    {
        var json = "{\"schema_version\":1,\"updated_at\":\"2026-10-21T03:00:00Z\",\"providers\":{\"claude\":{\"plan\":null,"
                   + "\"error\":null,\"windows\":[{\"id\":\"five_hour\",\"label\":\"5 小時\",\"used_pct\":1,\"resets_at\":null,"
                   + "\"forecast\":{\"urgent\":\"yes\"}}]}}}";
        Assert.Null(UsageDecoder.Decode(json).Providers["claude"].Windows[0].Forecast);
    }
}
