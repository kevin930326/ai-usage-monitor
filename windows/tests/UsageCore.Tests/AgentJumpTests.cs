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

    /// <summary>傳統主控台：視窗屬於 shell 的子程序 conhost 時算給 shell；shell 自己有視窗、父 PID 被重用、不是主控台程式時不算（Codex C-01）</summary>
    [Fact]
    public void ConsoleWindowsBelongToTheShell()
    {
        var names = new Dictionary<int, (int Parent, string Name)>
        {
            [100] = (1, "explorer.exe"),
            [200] = (100, "cmd.exe"),
            [201] = (200, "conhost.exe"),
            [202] = (200, "node.exe"),
            [300] = (100, "pwsh.exe"),
            [301] = (300, "OpenConsole.exe"),
            [400] = (100, "cmd.exe"),
            [401] = (400, "conhost.exe"),
            [500] = (100, "cmd.exe"),
            [501] = (500, "conhost.exe"),
            [600] = (100, "cmd.exe"),
            [601] = (600, "notepad.exe"),
        };
        var starts = new Dictionary<int, long> { [100] = 1, [200] = 10, [201] = 11, [202] = 12, [300] = 20, [301] = 21, [400] = 30, [401] = 31, [500] = 50, [501] = 40, [600] = 60, [601] = 61 };
        var withWindow = new HashSet<int> { 100, 201, 301, 400, 401, 501, 601 };
        var owners = AgentJump.ConsoleOwners(names, withWindow, pid => starts.TryGetValue(pid, out var s) ? s : null);
        Assert.Equal(new Dictionary<int, int> { [200] = 201, [300] = 301 }, owners);
    }
}
