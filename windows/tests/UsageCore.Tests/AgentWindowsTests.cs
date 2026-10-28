using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace AIUsageMonitor.Core.Tests;

/// <summary>
/// Windows 的 hook（ADR-0019 第 1 節）：設定檔的合併（AgentHookConfig）與 inbox 的檔案規則（AgentInbox）。
/// 全部在暫存資料夾，不碰真的 ~/.claude 或 ~/.codex。
/// </summary>
public sealed class AgentWindowsTests : IDisposable
{
    private const string Exe = @"C:\Users\張 愷文\AppData\Local\Programs\AI Usage Monitor\aum-hook.exe";
    private readonly string home = Path.Combine(Path.GetTempPath(), "aum-agent-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(home)) Directory.Delete(home, recursive: true);
    }

    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);
    private static JsonObject Json(byte[] data) => JsonNode.Parse(data)!.AsObject();

    // MARK: - 設定檔

    [Fact]
    public void ClaudeUsesExecFormAndKeepsOthers()
    {
        var original = Bytes("""{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other.exe"}]}]},"z":1}""");
        var installed = AgentHookConfig.Install(original, AgentKind.Claude, Exe);
        var root = Json(installed);
        Assert.Equal(["model", "hooks", "z"], root.Select(p => p.Key));
        var stop = root["hooks"]!["Stop"]!.AsArray();
        Assert.Equal(2, stop.Count);
        Assert.Equal("other.exe", (string?)stop[0]!["hooks"]![0]!["command"]);
        var ours = stop[1]!["hooks"]![0]!.AsObject();
        Assert.Equal(Exe, (string?)ours["command"]);
        Assert.Equal("claude", (string?)ours["args"]![0]);
        Assert.Equal("continue", (string?)ours["onFailure"]);
        Assert.Equal(AgentNames.Installed(AgentKind.Claude).Count, root["hooks"]!.AsObject().Count);
        Assert.Equal(AgentHookStatus.Installed, AgentHookConfig.Status(installed, AgentKind.Claude, Exe));
        // 再裝一次不會多一份
        Assert.Equal(Encoding.UTF8.GetString(installed), Encoding.UTF8.GetString(AgentHookConfig.Install(installed, AgentKind.Claude, Exe)));
        // 移除後回到原本的內容（縮排除外）
        var removed = AgentHookConfig.Uninstall(installed)!;
        Assert.Equal(Json(original).ToJsonString(), Json(removed).ToJsonString());
        Assert.Null(AgentHookConfig.Uninstall(removed));
    }

    [Fact]
    public void CodexQuotesThePathWithSpacesAndCjk()
    {
        var root = Json(AgentHookConfig.Install(null, AgentKind.Codex, Exe));
        var handler = root["hooks"]!["Stop"]![0]!["hooks"]![0]!;
        Assert.Equal($"\"{Exe}\" codex", (string?)handler["commandWindows"]);
        Assert.True(AgentHookConfig.IsOurs(handler));
    }

    [Fact]
    public void StatusNeedsRepairWhenMovedOrMissingEvents()
    {
        var installed = AgentHookConfig.Install(null, AgentKind.Claude, Exe);
        var moved = AgentHookConfig.Status(installed, AgentKind.Claude, @"D:\Apps\aum-hook.exe");
        Assert.True(moved.NeedsRepair && moved.WrongPath);
        var partial = AgentHookConfig.Install(null, AgentKind.Claude, Exe, [AgentHookEvent.Stop]);
        var status = AgentHookConfig.Status(partial, AgentKind.Claude, Exe);
        Assert.True(status.NeedsRepair);
        Assert.Contains(AgentHookEvent.SessionStart, status.Missing);
        Assert.Equal(AgentHookStatus.NotInstalled, AgentHookConfig.Status(Bytes("{}"), AgentKind.Claude, Exe));
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("""{"hooks":[]}""")]
    [InlineData("""{"hooks":{"Stop":{}}}""")]
    [InlineData("{not json")]
    [InlineData("""{"a":1,"a":2}""")]
    public void RefusesShapesItCannotSafelyChange(string text)
    {
        Assert.Throws<AgentHookConfigException>(() => AgentHookConfig.Install(Bytes(text), AgentKind.Claude, Exe));
    }

    [Theory]
    [InlineData(@"C:\a\b.exe")]
    [InlineData(@"relative\aum-hook.exe")]
    [InlineData("C:\\a\"b\\aum-hook.exe")]
    [InlineData(@"C:\50%\aum-hook.exe")]
    [InlineData(@"C:\a&b\aum-hook.exe")]
    public void RefusesPathsThatBreakTheCommandLine(string path)
    {
        Assert.False(AgentHookConfig.IsUsablePath(path));
        Assert.Throws<AgentHookConfigException>(() => AgentHookConfig.Install(null, AgentKind.Codex, path));
    }

    [Fact]
    public void BomAndOtherEventsSurvive()
    {
        var data = Bytes("\uFEFF{\"hooks\":{\"Custom\":\"keep\"}}");
        var root = Json(AgentHookConfig.Install(data, AgentKind.Claude, Exe));
        Assert.Equal("keep", (string?)root["hooks"]!["Custom"]);
    }

    // MARK: - inbox

    private const string Input =
        """{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"C:\\Users\\張愷文\\work\\專案 A","prompt":"secret"}""";

    [Fact]
    public void HookWritesNothingBeforeTheAppPreparedTheInbox()
    {
        Assert.False(AgentInbox.Write(home, AgentKind.Claude, Bytes(Input), DateTimeOffset.UtcNow));
        AgentInbox.EnsureSalt(home);
        Assert.False(AgentInbox.Write(home, AgentKind.Claude, Bytes(Input), DateTimeOffset.UtcNow));
    }

    [Fact]
    public void WrittenFileHasNoFolderOrContent()
    {
        var salt = AgentInbox.EnsureSalt(home);
        Directory.CreateDirectory(AgentInbox.InboxDirectory(home));
        var now = DateTimeOffset.FromUnixTimeMilliseconds(1_761_650_000_000);
        Assert.True(AgentInbox.Write(home, AgentKind.Claude, Bytes(Input), now));
        var file = Assert.Single(Directory.GetFiles(AgentInbox.InboxDirectory(home)));
        var text = File.ReadAllText(file);
        Assert.Equal($"{{\"v\":1,\"ai\":\"claude\",\"ev\":\"PermissionRequest\",\"need\":\"permission\",\"sub\":false,\"sid\":\"{AgentInbox.SessionHash("s-1", salt)}\",\"t\":1761650000000,\"dir\":\"\"}}", text);
        Assert.DoesNotContain("專案", text);
        Assert.DoesNotContain("secret", text);
        Assert.Equal(16, AgentInbox.SessionHash("s-1", salt).Length);
    }

    [Fact]
    public void DrainSortsByTimeDropsBadFilesAndEmptiesTheInbox()
    {
        var salt = AgentInbox.EnsureSalt(home);
        var inbox = Directory.CreateDirectory(AgentInbox.InboxDirectory(home)).FullName;
        var t0 = DateTimeOffset.FromUnixTimeMilliseconds(1_761_650_000_000);
        var sid = AgentInbox.SessionHash("s-1", salt);
        // 亂序寫入：檔名的時間決定順序
        for (var i = 9; i >= 0; i--)
        {
            var message = new AgentHookMessage(AgentKind.Codex, AgentHookEvent.Stop, null, sid, t0.ToUnixTimeMilliseconds() + i, "");
            File.WriteAllBytes(Path.Combine(inbox, AgentInbox.FileName(t0.AddMilliseconds(i), $"{i:x8}")), message.Encoded());
        }
        File.WriteAllText(Path.Combine(inbox, AgentInbox.FileName(t0, "bad00000")), "not json");
        File.WriteAllText(Path.Combine(inbox, AgentInbox.FileName(t0, "dir00000")),
            Encoding.UTF8.GetString(new AgentHookMessage(AgentKind.Codex, AgentHookEvent.Stop, null, sid, 1, "has-folder").Encoded()));
        File.WriteAllBytes(Path.Combine(inbox, AgentInbox.FileName(t0, "big00000")), new byte[4096]);
        var seen = new HashSet<string>();
        var messages = AgentInbox.Drain(home, seen);
        Assert.Equal(Enumerable.Range(0, 10).Select(i => t0.ToUnixTimeMilliseconds() + i), messages.Select(m => m.Time));
        Assert.Empty(Directory.GetFiles(inbox));
        Assert.Empty(seen);
    }

    [Fact]
    public void FullInboxStopsTheHook()
    {
        AgentInbox.EnsureSalt(home);
        var inbox = Directory.CreateDirectory(AgentInbox.InboxDirectory(home)).FullName;
        for (var i = 0; i < AgentInbox.MaxFiles; i++) File.WriteAllText(Path.Combine(inbox, $"{i:D20}-x.json"), "");
        Assert.False(AgentInbox.Write(home, AgentKind.Claude, Bytes(Input), DateTimeOffset.UtcNow));
        AgentInbox.Clear(home);
        Assert.Empty(Directory.GetFiles(inbox));
        Assert.True(AgentInbox.Write(home, AgentKind.Claude, Bytes(Input), DateTimeOffset.UtcNow));
    }

    [Fact]
    public void FileNamesSortByTime()
    {
        var a = AgentInbox.FileName(DateTimeOffset.FromUnixTimeMilliseconds(999), "ffffffff");
        var b = AgentInbox.FileName(DateTimeOffset.FromUnixTimeMilliseconds(1000), "00000000");
        Assert.True(string.CompareOrdinal(a, b) < 0);
    }
}
