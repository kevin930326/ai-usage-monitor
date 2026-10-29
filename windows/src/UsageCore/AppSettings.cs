using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

/// <summary>顯示方式：懸浮圓環、系統匣圖示，或兩者。</summary>
public enum DisplayMode { Both, Ring, Tray }

/// <summary>圓環大小（DIP 邊長）</summary>
public enum RingSize { Small, Medium, Large }

/// <summary>外觀：跟隨系統、淺色、深色（FR-51）</summary>
public enum Appearance { System, Light, Dark }

/// <summary>
/// Windows App 自己的設定（<c>%LOCALAPPDATA%\AIUsageMonitor\windows-app.json</c>，ADR-0015 第 8 節）。
/// App 只寫這個檔案；讀不到或格式不對的欄位用預設值，不認得的欄位保留（新版加的設定，舊版改其他設定時不會刪掉）。
/// </summary>
public sealed class AppSettings
{
    public const int Schema = 1;
    public const double MinimumOpacity = 0.3;

    public DisplayMode DisplayMode { get; set; } = DisplayMode.Both;
    public WindowChoice RingWindow { get; set; } = WindowChoice.Automatic;
    public RingSize RingSize { get; set; } = RingSize.Medium;
    private double opacity = 1;
    /// <summary>圓環的透明度 0.3～1</summary>
    public double Opacity { get => opacity; set => opacity = double.IsFinite(value) ? Math.Clamp(value, MinimumOpacity, 1) : 1; }
    public bool HideInFullscreen { get; set; } = true;
    /// <summary>開機自動啟動。實際狀態在登錄機碼（安裝腳本也讀這個值決定要不要寫入）</summary>
    public bool LaunchAtLogin { get; set; } = true;
    public Appearance Appearance { get; set; } = Appearance.System;
    /// <summary>圓環貼在左右邊緣時縮成半圓的小標籤（滑鼠移上去滑出）</summary>
    public bool DockToEdge { get; set; } = true;
    /// <summary>圓環外圍顯示 60 格刻度（這個額度週期過了多少時間）</summary>
    public bool RingTicks { get; set; }
    /// <summary>AI 需要你超過幾秒發通知（0＝關閉；ADR-0019，同 Mac）</summary>
    public int AgentNeedsYouSeconds { get; set; } = 20;
    /// <summary>跑超過幾分鐘的任務完成時發通知（0＝關閉）</summary>
    public int AgentLongTaskMinutes { get; set; } = 3;
    /// <summary>懸浮圖示的樣式（預設角色；可切回 C2 圓環或角色加百分比）</summary>
    public RingStyle RingStyle { get; set; } = RingStyle.Mascot;
    /// <summary>角色的服務色：claude 或 codex（同 Mac 的「角色」）</summary>
    public string MascotProvider { get; set; } = "claude";
    /// <summary>角色外觀（shared/mascot-looks.json 的代號）；null 是跟著服務色</summary>
    public string? MascotLook { get; set; }
    public MascotIntroChoice MascotIntro { get; set; } = MascotIntroChoice.FirstOnly;
    public MascotMotionLevel MascotMotion { get; set; } = MascotMotionLevel.Full;
    /// <summary>眼睛跟著游標</summary>
    public bool MascotFollowPointer { get; set; } = true;
    /// <summary>Claude 與 Codex 都閒置幾分鐘後睡</summary>
    /// <summary>睡覺的分鐘數。預設 20（ADR-0017 第 4 節，2026-10-29 從 5 改成 20）；設定檔只有在使用者選過（<see cref="MascotSleepChosen"/>）時才照檔案的值</summary>
    public int MascotSleepMinutes { get; set; } = DefaultSleepMinutes;
    /// <summary>使用者在設定裡選過睡覺分鐘數。舊版不分選過與否都寫進設定檔：沒有這個標記時，5 分鐘當成當時的預設（改用新的預設），其他值當成選過</summary>
    public bool MascotSleepChosen { get; set; }
    public const int DefaultSleepMinutes = 20;
    /// <summary>等你下一個指令時，收著的角色每 7 秒輕輕脈動</summary>
    public bool MascotWaitingPulse { get; set; } = true;
    /// <summary>靜音或勿擾到這個時間（不播提醒、不鼓一下；只換表情）</summary>
    public DateTimeOffset? MascotQuietUntil { get; set; }
    public List<SavedPosition> Positions { get; set; } = [];
    public List<DateTimeOffset> CollectorKicks { get; set; } = [];

    private JsonObject extra = [];

    public static readonly int[] NeedsYouSecondChoices = [0, 10, 20, 30, 60, 120];
    public static readonly int[] LongTaskMinuteChoices = [0, 1, 3, 5, 10, 20];
    public static readonly int[] SleepMinuteChoices = [1, 3, 5, 10, 15, 20, 30];

    public bool IsMascotQuiet(DateTimeOffset now) => MascotQuietUntil is { } until && until > now;

    public AgentNoticePolicy AgentNoticePolicy => new(
        AgentNeedsYouSeconds > 0 ? AgentNeedsYouSeconds * 1000L : long.MaxValue,
        AgentLongTaskMinutes > 0 ? AgentLongTaskMinutes * 60_000L : long.MaxValue);

    public bool ShowsRing => DisplayMode != DisplayMode.Tray;
    public bool ShowsTray => DisplayMode != DisplayMode.Ring;

    public static double RingDip(RingSize size) => size switch
    {
        RingSize.Small => 40,
        RingSize.Large => 72,
        _ => 56,
    };

    public static AppSettings Parse(string? json)
    {
        var settings = new AppSettings();
        JsonObject? root = null;
        try
        {
            root = string.IsNullOrWhiteSpace(json) ? null : JsonNode.Parse(json) as JsonObject;
        }
        catch (JsonException)
        {
        }
        if (root is null) return settings;
        settings.DisplayMode = Enum(root["display_mode"], DisplayMode.Both);
        settings.RingWindow = WindowChoice.Parse(Text(root["ring_window"]));
        settings.RingSize = Enum(root["ring_size"], RingSize.Medium);
        if (Number(root["opacity"]) is { } o) settings.Opacity = o;
        settings.HideInFullscreen = Bool(root["hide_in_fullscreen"]) ?? true;
        settings.LaunchAtLogin = Bool(root["launch_at_login"]) ?? true;
        settings.Appearance = Enum(root["appearance"], Appearance.System);
        settings.DockToEdge = Bool(root["dock_to_edge"]) ?? true;
        settings.RingTicks = Bool(root["ring_ticks"]) ?? false;
        settings.AgentNeedsYouSeconds = Choice(Number(root["agent_needs_you_seconds"]), NeedsYouSecondChoices, 20);
        settings.AgentLongTaskMinutes = Choice(Number(root["agent_long_task_minutes"]), LongTaskMinuteChoices, 3);
        settings.RingStyle = Enum(root["ring_style"], RingStyle.Mascot);
        settings.MascotProvider = Text(root["mascot_provider"]) is "codex" ? "codex" : "claude";
        settings.MascotLook = Text(root["mascot_look"]) is { Length: > 0 and <= 32 } look ? look : null;
        settings.MascotIntro = Enum(root["mascot_intro"], MascotIntroChoice.FirstOnly);
        settings.MascotMotion = Enum(root["mascot_motion"], MascotMotionLevel.Full);
        settings.MascotFollowPointer = Bool(root["mascot_follow_pointer"]) ?? true;
        // 舊版沒有標記、不分選過與否都寫：不是 5（舊的預設）就是使用者選的
        var storedSleep = Number(root["mascot_sleep_minutes"]);
        settings.MascotSleepChosen = Bool(root["mascot_sleep_chosen"]) ?? (storedSleep is { } m && m != 5);
        settings.MascotSleepMinutes = settings.MascotSleepChosen
            ? Choice(storedSleep, SleepMinuteChoices, DefaultSleepMinutes)
            : DefaultSleepMinutes;
        settings.MascotWaitingPulse = Bool(root["mascot_waiting_pulse"]) ?? true;
        if (Number(root["mascot_quiet_until"]) is { } quiet && quiet is > 0 and < 1e11)
            settings.MascotQuietUntil = DateTimeOffset.FromUnixTimeSeconds((long)quiet);
        if (root["positions"] is JsonArray positions)
        {
            foreach (var p in positions.OfType<JsonObject>())
            {
                if (Text(p["key"]) is { } key && Number(p["x"]) is { } x && Number(p["y"]) is { } y)
                {
                    settings.Positions.Add(new SavedPosition(key, (int)x, (int)y, (long)(Number(p["used"]) ?? 0)));
                }
            }
            settings.Positions = [.. settings.Positions.OrderByDescending(p => p.Used).Take(RingPlacement.MaxSavedPositions)];
        }
        if (root["collector_kicks"] is JsonArray kicks)
        {
            foreach (var k in kicks)
            {
                if (Number(k) is { } seconds && seconds is > 0 and < 1e11) settings.CollectorKicks.Add(DateTimeOffset.FromUnixTimeSeconds((long)seconds));
            }
        }
        foreach (var (key, value) in root)
        {
            if (!Known.Contains(key)) settings.extra[key] = value?.DeepClone();
        }
        return settings;
    }

    public string Serialize()
    {
        var root = new JsonObject
        {
            ["schema"] = Schema,
            ["display_mode"] = Name(DisplayMode),
            ["ring_window"] = RingWindow.RawValue,
            ["ring_size"] = Name(RingSize),
            ["opacity"] = Math.Round(Opacity, 2),
            ["hide_in_fullscreen"] = HideInFullscreen,
            ["launch_at_login"] = LaunchAtLogin,
            ["appearance"] = Name(Appearance),
            ["dock_to_edge"] = DockToEdge,
            ["ring_ticks"] = RingTicks,
            ["agent_needs_you_seconds"] = AgentNeedsYouSeconds,
            ["agent_long_task_minutes"] = AgentLongTaskMinutes,
            ["ring_style"] = Name(RingStyle),
            ["mascot_provider"] = MascotProvider,
            ["mascot_look"] = MascotLook,
            ["mascot_intro"] = Name(MascotIntro),
            ["mascot_motion"] = Name(MascotMotion),
            ["mascot_follow_pointer"] = MascotFollowPointer,
            ["mascot_sleep_minutes"] = MascotSleepMinutes,
            ["mascot_sleep_chosen"] = MascotSleepChosen,
            ["mascot_waiting_pulse"] = MascotWaitingPulse,
            ["mascot_quiet_until"] = MascotQuietUntil is { } q ? JsonValue.Create(q.ToUnixTimeSeconds()) : null,
            ["positions"] = new JsonArray([.. Positions.Select(p => (JsonNode)new JsonObject { ["key"] = p.Key, ["x"] = p.X, ["y"] = p.Y, ["used"] = p.Used })]),
            ["collector_kicks"] = new JsonArray([.. CollectorKicks.Select(k => (JsonNode)JsonValue.Create(k.ToUnixTimeSeconds()))]),
        };
        foreach (var (key, value) in extra) root[key] = value?.DeepClone();
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static readonly HashSet<string> Known =
    [
        "schema", "display_mode", "ring_window", "ring_size", "opacity", "hide_in_fullscreen", "launch_at_login", "appearance",
        "dock_to_edge", "ring_ticks", "agent_needs_you_seconds", "agent_long_task_minutes",
        "ring_style", "mascot_provider", "mascot_look", "mascot_intro", "mascot_motion", "mascot_follow_pointer",
        "mascot_sleep_minutes", "mascot_waiting_pulse", "mascot_quiet_until",
        "positions", "collector_kicks",
    ];

    private static int Choice(double? value, int[] choices, int fallback) =>
        value is { } v && choices.Contains((int)v) && v == Math.Floor(v) ? (int)v : fallback;

    private static string Name<T>(T value) where T : struct, Enum => value.ToString().ToLowerInvariant();

    private static T Enum<T>(JsonNode? node, T fallback) where T : struct, Enum =>
        Text(node) is { } s && System.Enum.TryParse<T>(s, ignoreCase: true, out var v) && System.Enum.IsDefined(v) && !int.TryParse(s, out _) ? v : fallback;

    private static string? Text(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    private static double? Number(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : null;

    private static bool? Bool(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? v.GetValue<bool>() : null;
}
