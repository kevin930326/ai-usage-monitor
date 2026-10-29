using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// 點工作階段跳回那個 session（ADR-0017 第 10 節）：fixtures/agent-jump/cases.json 的程序樹，和 Swift 的 AgentJumpTests 同一份。
/// Windows 只看 windows 的結果（tmux、tty 是 Mac 的）
/// </summary>
public class AgentJumpTests
{
    [Fact]
    public void WalksTheProcessTree()
    {
        var root = LogicGoldenTests.RepoRoot;
        var hosts = AgentHosts.Decode(File.ReadAllText(Path.Combine(root, "shared", "agent-hosts.json")));
        var cases = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "fixtures", "agent-jump", "cases.json")))!["walk"]!.AsArray();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            var table = c!["processes"]!.AsArray().Select(p => new AgentJump.Process(
                p!["pid"]!.GetValue<int>(), p["ppid"]!.GetValue<int>(), p["start"]!.GetValue<long>(), p["name"]!.GetValue<string>(),
                p["window"]?.GetValue<bool>() ?? false)).ToDictionary(p => p.Pid);
            var start = c["start"]?.GetValue<long>();
            var expected = c["windows"]?["pid"]?.GetValue<int>();
            var actual = AgentJump.WindowsTarget(c["ai"]!.GetValue<int>(), start, hosts, pid => table.GetValueOrDefault(pid));
            Assert.True(expected == actual, $"{c["name"]}: expected {expected}, got {actual}");
        }
    }
}
