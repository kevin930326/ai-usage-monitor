using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// usage.json 的選填事故（ADR-0018 第 4 節）：讀 fixtures/usage-forecast-incidents.json（Swift、中繼與收集器的測試讀同一份）。
/// Windows App 有本機歷史，預測自己算，不讀快照裡的 <c>forecast</c>。
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
        Assert.Equal("https://status.claude.com/incidents/abc123", incident.Link?.AbsoluteUri);
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

    [Theory]
    [InlineData("http://status.claude.com/incidents/x")]
    [InlineData("https://evil.example/incidents/x")]
    [InlineData("https://status.claude.com/x")]
    [InlineData("https://status.claude.com.evil.example/incidents/x")]
    [InlineData("https://u@status.openai.com/incidents/x")]
    [InlineData("https://status.openai.com:8443/incidents/x")]
    [InlineData("javascript:alert(1)")]
    public void LinksOnlyForStatusPages(string bad) => Assert.Null(ServiceIncident.LinkOf(bad));

    [Fact]
    public void StatusPageLinkIsKept() => Assert.NotNull(ServiceIncident.LinkOf("https://status.openai.com/incidents/01J"));
}
