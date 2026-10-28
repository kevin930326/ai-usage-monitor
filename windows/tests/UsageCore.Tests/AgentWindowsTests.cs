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
    [InlineData("""{"hooks":{"Stop":[],"Stop":[]}}""")]
    [InlineData("""{"hooks":{"Stop":[{"matcher":"","matcher":"x","hooks":[]}]}}""")]
    [InlineData("""{"hooks":{"Stop":[{"hooks":[{"type":"command","type":"x"}]}]}}""")]
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
    public void LateBatchesUseTheEventTime()
    {
        var sessions = new AgentSessions(600_000);
        const long t0 = 1_761_650_000_000;
        var sid = "0123456789abcdef";
        // 每分鐘的退路掃描才讀到：開始與完成相隔 5 分鐘，算長任務
        AgentInbox.Apply(sessions, [
            new AgentHookMessage(AgentKind.Claude, AgentHookEvent.UserPromptSubmit, null, sid, t0, ""),
            new AgentHookMessage(AgentKind.Claude, AgentHookEvent.Stop, null, sid, t0 + 300_000, ""),
        ], t0 + 360_000);
        var notice = Assert.Single(AgentNotices.Due(sessions, t0 + 360_000, new AgentNoticePolicy()));
        Assert.Equal(AgentNoticeKind.Done, notice.Kind);
        // 當機前留下的 13 小時前的需要你：立刻淘汰
        var old = new AgentSessions(600_000);
        AgentInbox.Apply(old, [new AgentHookMessage(AgentKind.Codex, AgentHookEvent.PermissionRequest, AgentNeed.Permission, sid, t0, "")],
                         t0 + 13 * 3_600_000);
        Assert.Empty(old.Sessions);
        // 未來的時間（時鐘被調過）不超過現在
        var future = new AgentSessions(600_000);
        AgentInbox.Apply(future, [new AgentHookMessage(AgentKind.Codex, AgentHookEvent.PermissionRequest, AgentNeed.Permission, sid, t0 + 999_999, "")], t0);
        Assert.Equal(t0, Assert.Single(future.Sessions).Since);
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

    // MARK: - 設定檔的讀寫

    private string Config(string name) => Path.Combine(home, "fake-claude", name);

    [Fact]
    public void ConnectBacksUpAndDisconnectRestores()
    {
        var file = Config("settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, """{"model":"x"}""");
        var now = new DateTime(2026, 10, 29, 9, 30, 0);
        var connected = AgentHookFiles.Connect(file, AgentKind.Claude, Exe, now);
        Assert.True(connected.Written);
        Assert.Equal(file + ".aum-backup-20261029-093000", connected.Backup);
        Assert.Equal("""{"model":"x"}""", File.ReadAllText(connected.Backup!));
        Assert.Equal(AgentHookStatus.Installed, AgentHookFiles.Status(file, AgentKind.Claude, Exe, exeExists: true));
        // 已經連接好：不寫、不多一份備份
        Assert.False(AgentHookFiles.Connect(file, AgentKind.Claude, Exe, now).Written);
        var removed = AgentHookFiles.Disconnect(file, now);
        Assert.Equal(file + ".aum-backup-20261029-093000-2", removed.Backup);
        Assert.Equal("x", (string?)Json(File.ReadAllBytes(file))["model"]);
        Assert.False(AgentHookFiles.Disconnect(file, now).Written);
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(file)!, ".*.tmp"));
    }

    [Fact]
    public void BackupAndReplacementKeepThePermissions()
    {
        if (OperatingSystem.IsWindows())
        {
            KeepsTheDaclOnWindows();
            return;
        }
        var file = Config("settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "{}");
        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        var result = AgentHookFiles.Connect(file, AgentKind.Claude, Exe, DateTime.Now);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(file));
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(result.Backup!));
    }

    /// <summary>原檔只有自己能讀（不繼承資料夾）：備份與換上的檔案也一樣</summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private void KeepsTheDaclOnWindows()
    {
        var file = Config("settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "{}");
        var me = System.Security.Principal.WindowsIdentity.GetCurrent().User!;
        var only = new System.Security.AccessControl.FileSecurity();
        only.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        only.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(me, System.Security.AccessControl.FileSystemRights.FullControl,
                                                                                  System.Security.AccessControl.AccessControlType.Allow));
        new FileInfo(file).SetAccessControl(only);
        // 比較「不繼承（P）」與存取規則；「AI」只表示 ACL 是怎麼傳播來的，以安全描述元建立的檔案不會有（D:PAI → D:P）
        string Sddl(string path) => new FileInfo(path).GetAccessControl(System.Security.AccessControl.AccessControlSections.Access)
            .GetSecurityDescriptorSddlForm(System.Security.AccessControl.AccessControlSections.Access).Replace("D:PAI(", "D:P(");
        var expected = Sddl(file);
        var result = AgentHookFiles.Connect(file, AgentKind.Claude, Exe, DateTime.Now);
        Assert.Equal(expected, Sddl(file));
        Assert.Equal(expected, Sddl(result.Backup!));
    }

    [Fact]
    public void MissingFileIsCreatedWithoutBackup()
    {
        var file = Config("hooks.json");
        var result = AgentHookFiles.Connect(file, AgentKind.Codex, Exe, DateTime.Now);
        Assert.True(result.Written);
        Assert.Null(result.Backup);
        Assert.Equal(AgentHookStatus.NotInstalled, AgentHookFiles.Status(Config("none.json"), AgentKind.Codex, Exe, exeExists: true));
    }

    [Fact]
    public void MissingHookProgramNeedsRepair()
    {
        var file = Config("settings.json");
        AgentHookFiles.Connect(file, AgentKind.Claude, Exe, DateTime.Now);
        var status = AgentHookFiles.Status(file, AgentKind.Claude, Exe, exeExists: false);
        Assert.True(status.NeedsRepair && status.WrongPath);
    }

    [Fact]
    public void KeepsOnlyTheNewestBackups()
    {
        var file = Config("settings.json");
        var now = new DateTime(2026, 10, 29, 9, 0, 0);
        AgentHookFiles.Connect(file, AgentKind.Claude, Exe, now);
        for (var i = 1; i <= 5; i++)
        {
            AgentHookFiles.Disconnect(file, now.AddSeconds(i * 2));
            AgentHookFiles.Connect(file, AgentKind.Claude, Exe, now.AddSeconds(i * 2 + 1));
        }
        var backups = Directory.GetFiles(Path.GetDirectoryName(file)!, "settings.json.aum-backup-*").Select(Path.GetFileName).Order().ToList();
        Assert.Equal(["settings.json.aum-backup-20261029-090009", "settings.json.aum-backup-20261029-090010", "settings.json.aum-backup-20261029-090011"], backups);
    }

    [Fact]
    public void ChangedBetweenReadAndReplaceIsMergedAgain()
    {
        var file = Config("settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, """{"a":1}""");
        var once = true;
        AgentHookFiles.Connect(file, AgentKind.Claude, Exe, DateTime.Now, () =>
        {
            if (!once) return;
            once = false;
            File.WriteAllText(file, """{"a":1,"b":2}""");
        });
        var root = Json(File.ReadAllBytes(file));
        Assert.Equal(2, (int?)root["b"]);
        Assert.NotNull(root["hooks"]);
        // 一直被改：放棄，不覆蓋
        var other = Config("other.json");
        Assert.Throws<AgentHookConfigException>(() =>
            AgentHookFiles.Connect(other, AgentKind.Claude, Exe, DateTime.Now, () => File.WriteAllText(other, Guid.NewGuid().ToString())));
    }

    [Fact]
    public void ConfigDirectoryFollowsTheCollector()
    {
        const string user = @"C:\Users\me";
        static string? NoEnv(string _) => null;
        static string? Env(string name) => name == "CLAUDE_CONFIG_DIR" ? @"D:\claude" : name == "CODEX_HOME" ? "~/codex" : null;
        Assert.Equal(Path.Combine(user, ".claude"), AgentHookFiles.ConfigDirectory(AgentKind.Claude, null, NoEnv, user));
        Assert.Equal(@"D:\claude", AgentHookFiles.ConfigDirectory(AgentKind.Claude, null, Env, user));
        Assert.Equal(Path.Combine(user, "codex"), AgentHookFiles.ConfigDirectory(AgentKind.Codex, null, Env, user));
        var config = Bytes("""{"claude_config_dir":"E:\\cc","codex_home":""}""");
        Assert.Equal(@"E:\cc", AgentHookFiles.ConfigDirectory(AgentKind.Claude, config, Env, user));
        Assert.Equal(Path.Combine(user, "codex"), AgentHookFiles.ConfigDirectory(AgentKind.Codex, config, Env, user));
        Assert.Equal(Path.Combine(user, ".codex"), AgentHookFiles.ConfigDirectory(AgentKind.Codex, Bytes("not json"), NoEnv, user));
    }

    [Theory]
    [InlineData("[features]\nhooks = false\n", true)]
    [InlineData("[features]\r\ncodex_hooks = false # 舊名\r\n", true)]
    [InlineData("features.hooks = false\n", true)]
    [InlineData("[features]\nhooks = true\n", false)]
    [InlineData("[other]\nhooks = false\n", false)]
    [InlineData("# [features]\nhooks = false\n", false)]
    public void CodexFeatureFlag(string toml, bool disabled)
    {
        Assert.Equal(disabled, AgentHookFiles.CodexHooksDisabled(Bytes(toml)));
    }

    // MARK: - 圓環與通知

    private static AgentHookMessage Event(AgentHookEvent e, long t, AgentNeed? need = null, AgentKind ai = AgentKind.Claude) =>
        new(ai, e, need, "0123456789abcdef", t, "");

    [Fact]
    public void RingShowsOnlyWhatNeedsAttention()
    {
        var sessions = new AgentSessions(600_000);
        sessions.Apply(Event(AgentHookEvent.UserPromptSubmit, 1), 1_000);
        Assert.Null(RingAgent.From(sessions, 2_000));
        sessions.Apply(Event(AgentHookEvent.PermissionRequest, 2), 2_000);
        var agent = RingAgent.From(sessions, 3_000)!;
        Assert.Equal(new RingAgent(AgentKind.Claude, AgentState.NeedsYou, AgentNeed.Permission), agent);
        Assert.Equal("Claude Code 需要你", agent.Title);
        Assert.Equal("等你允許一個動作", agent.Detail);
        var content = RingContent.Empty.WithAgent(agent);
        Assert.StartsWith("Claude Code 需要你：等你允許一個動作\n", content.Tooltip);
        Assert.NotEqual(RingContent.Empty, content);
        sessions.Apply(Event(AgentHookEvent.Stop, 3), 3_000);
        Assert.Equal(AgentState.Done, RingAgent.From(sessions, 4_000)!.State);
        sessions.MarkSeen(5_000);
        Assert.Null(RingAgent.From(sessions, 6_000));
    }

    [Fact]
    public void RingFallsBackToAnotherComputerThatNeedsYou()
    {
        var sessions = new AgentSessions(600_000);
        var remote = new List<RemoteAgent>
        {
            new("工作 PC", AgentKind.Codex, AgentState.NeedsYou, 1),
            new("桌機", AgentKind.Claude, AgentState.Done, 1),
        };
        var agent = RingAgent.From(sessions, 1_000, remote)!;
        Assert.Equal(new RingAgent(AgentKind.Codex, AgentState.NeedsYou, null, "工作 PC"), agent);
        Assert.Equal("工作 PC：Codex 需要你", agent.Title);
        Assert.Equal("在另一台電腦", agent.Detail);
        // 其他電腦的完成、出錯、工作中不上圓環（這裡看過也消不掉）
        Assert.Null(RingAgent.From(sessions, 1_000, [new("桌機", AgentKind.Claude, AgentState.Done, 1),
                                                     new("桌機", AgentKind.Codex, AgentState.Error, 1),
                                                     new("筆電", AgentKind.Claude, AgentState.Working, 2)]));
        // 這台有要注意的時以這台為主
        sessions.Apply(Event(AgentHookEvent.Stop, 2), 2_000);
        Assert.Null(RingAgent.From(sessions, 3_000, remote)!.Device);
    }

    [Fact]
    public void NoticeLogSendsOncePerState()
    {
        var sessions = new AgentSessions(600_000);
        var policy = new AgentNoticePolicy(NeedsYouAfter: 20_000);
        var log = new AgentNoticeLog();
        sessions.Apply(Event(AgentHookEvent.PermissionRequest, 1), 0);
        Assert.Empty(log.Take(sessions, 10_000, policy));
        var first = Assert.Single(log.Take(sessions, 20_000, policy));
        Assert.Equal(("Claude Code 需要你", "等你允許一個動作"), AgentText.Notice(first, 3));
        Assert.Empty(log.Take(sessions, 30_000, policy));
        // 批准後又要求一次：新的一段狀態，再發一次
        sessions.Apply(Event(AgentHookEvent.PostToolUse, 2), 31_000);
        sessions.Apply(Event(AgentHookEvent.PermissionRequest, 3), 32_000);
        Assert.Single(log.Take(sessions, 52_000, policy));
        Assert.Equal(("Codex 完成了", "跑了 5 分鐘以上的任務完成了"),
                     AgentText.Notice(new AgentNotice(AgentKind.Codex, AgentNoticeKind.Done, null, "k"), 5));
    }

    [Fact]
    public void SettingsKeepOnlyKnownChoices()
    {
        var settings = AppSettings.Parse("""{"agent_needs_you_seconds":30,"agent_long_task_minutes":7}""");
        Assert.Equal(30, settings.AgentNeedsYouSeconds);
        Assert.Equal(3, settings.AgentLongTaskMinutes);
        settings.AgentNeedsYouSeconds = 0;
        Assert.Equal(long.MaxValue, settings.AgentNoticePolicy.NeedsYouAfter);
        Assert.Equal(180_000, settings.AgentNoticePolicy.LongTask);
        Assert.Equal(0, AppSettings.Parse(settings.Serialize()).AgentNeedsYouSeconds);
    }
}
