#if DEBUG
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 只在 Debug 版：示範資料與截圖（ADR-0015 第 8 節）。CI 檢查 Release 的執行檔不含這些字串。
/// - <c>--demo &lt;情境&gt;</c>：把示範的 usage.json 寫到暫存資料夾，以它當 AI_USAGE_MONITOR_HOME 照常啟動
/// - <c>--render &lt;資料夾&gt; --now &lt;ISO&gt;</c>：不顯示視窗，以固定時間把圓環四種狀態、系統匣圖示、面板與設定（淺色、深色）存成 PNG
/// </summary>
internal static class DebugTools
{
    public static readonly string[] Scenarios = ["normal", "too_fast", "forecast", "critical", "stale", "error", "single", "none"];

    public static bool TryRun(string[] args, out int code)
    {
        code = 0;
        var demo = Value(args, "--demo");
        if (Value(args, "--render") is { } output)
        {
            var now = Value(args, "--now") is { } text && UsageDecoder.TryParseIso(text, out var parsed) ? parsed : DateTimeOffset.UtcNow;
            code = Render(output, now);
            return true;
        }
        if (demo is not null)
        {
            var home = Path.Combine(Path.GetTempPath(), "aum-demo-" + demo);
            Directory.CreateDirectory(home);
            File.WriteAllText(Path.Combine(home, "usage.json"), DemoJson(demo, DateTimeOffset.UtcNow), new UTF8Encoding(false));
            Environment.SetEnvironmentVariable("AI_USAGE_MONITOR_HOME", home);
            AppMode.Isolated = true;
        }
        return false;
    }

    private static string? Value(string[] args, string name)
    {
        var i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    // ---------- 示範資料 ----------

    public static string DemoJson(string scenario, DateTimeOffset now)
    {
        string At(double hours) => now.AddHours(hours).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        string Window(string id, string label, double used, double resetsInHours) =>
            $$"""{"id": "{{id}}", "label": "{{label}}", "used_pct": {{used.ToString(CultureInfo.InvariantCulture)}}, "resets_at": "{{At(resetsInHours)}}"}""";
        string Provider(string plan, params string[] windows) => $$"""{"plan": "{{plan}}", "windows": [{{string.Join(", ", windows)}}]}""";
        var claude = Provider("Max", Window("five_hour", "5 小時", 27, 3.2), Window("weekly", "每週", 37, 98));
        var codex = Provider("Plus", Window("five_hour", "5 小時", 10, 4.1), Window("weekly", "每週", 22, 130));
        var updated = At(-0.08);
        switch (scenario)
        {
            case "too_fast":
                // 5 小時額度過了 30% 就用了 60%：照目前速度會在重置前用完
                claude = Provider("Max", Window("five_hour", "5 小時", 60, 3.5), Window("weekly", "每週", 45, 98));
                break;
            case "forecast":
                // 額度預測與服務事故（ADR-0018）：事故有連結（整行是按鈕、右邊有 ↗；網址只能從 IncidentLink 組，ADR-0015 第 2 節），5 小時 40 分鐘後用完（紅）、每週約 30 小時後用完（黃），Claude 有進行中的事故
                claude = $$"""{"plan": "Max", "windows": [{"id": "five_hour", "label": "5 小時", "used_pct": 80, "resets_at": "{{At(2)}}", "forecast": {"exhausts_at": "{{At(0.67)}}", "urgent": true, "faster": 2.1} }, {"id": "weekly", "label": "每週", "used_pct": 60, "resets_at": "{{At(72)}}", "forecast": {"exhausts_at": "{{At(30.5)}}", "urgent": false} }], "incidents": [{"name": "Elevated errors on Claude Code", "impact": "major", "url": "{{IncidentLink.AllowedPrefixes[0]}}demo01", "started_at": "{{At(-0.33)}}"}]}""";
                break;
            case "critical":
                claude = Provider("Max", Window("five_hour", "5 小時", 40, 2.0), Window("weekly", "每週", 88, 30));
                break;
            case "stale":
                updated = At(-2);
                break;
            case "error":
                codex = """{"plan": null, "error": "codex app-server 沒有回應（30 秒逾時）", "windows": []}""";
                break;
            case "single":
                return $$"""{"schema_version": 1, "updated_at": "{{updated}}", "providers": {"codex": {{codex}} } }""";
            case "none":
                return $$"""{"schema_version": 1, "updated_at": "{{updated}}", "providers": {} }""";
        }
        return $$"""{"schema_version": 1, "updated_at": "{{updated}}", "providers": {"claude": {{claude}}, "codex": {{codex}} } }""";
    }

    // ---------- 截圖 ----------

    private const double Scale = 2;

    /// <summary>截圖上顯示的資料夾（設定、沒有資料的面板）：固定的示範路徑，不帶出這台電腦的使用者名稱或真正的資料位置</summary>
    private const string DemoHome = @"C:\Users\demo\AppData\Local\AIUsageMonitor";

    private static int Render(string output, DateTimeOffset now)
    {
        Directory.CreateDirectory(output);
        Clock.Fixed = now;
        // 只在這個程序裡；截圖不讀寫檔案，也不改開機自動啟動、不觸發收集器
        Environment.SetEnvironmentVariable("AI_USAGE_MONITOR_HOME", DemoHome);
        AppMode.Isolated = true;
        var failures = new List<string>();
        foreach (var dark in new[] { false, true })
        {
            SystemLook.ForcedDark = dark;
            var theme = dark ? "dark" : "light";
            var palette = new Palette(dark);
            foreach (var state in new[] { "normal", "too_fast", "critical", "stale" })
            {
                var snapshot = UsageDecoder.Decode(DemoJson(state, now));
                var content = RingContent.From(snapshot, WindowChoice.Automatic, now);
                Save(Path.Combine(output, $"tray-{state}-{theme}.png"), TrayIcon.RenderBitmap(content, palette, 64), failures);
            }
            foreach (var (name, agent) in AgentStates)
            {
                var content = RingContent.From(UsageDecoder.Decode(DemoJson("normal", now)), WindowChoice.Automatic, now).WithAgent(agent);
                Save(Path.Combine(output, $"tray-agent-{name}-{theme}.png"), TrayIcon.RenderBitmap(content, palette, 64), failures);
            }
            RenderRing2(Path.Combine(output, "ring2"), palette, theme, now, failures);
            RenderMascot(Path.Combine(output, "mascot"), palette, theme, now, failures);
            foreach (var scenario in Scenarios)
            {
                var model = new PanelModel(UsageDecoder.Decode(DemoJson(scenario, now)), null, now, null);
                Save(Path.Combine(output, $"panel-{scenario}-{theme}.png"), Element(new PanelContent(model, palette) { Background = palette.Solid }), failures);
            }
            Save(Path.Combine(output, $"panel-nodata-{theme}.png"),
                 Element(new PanelContent(new PanelModel(null, null, now, null), palette) { Background = palette.Solid }), failures);
            Save(Path.Combine(output, $"panel-hint-{theme}.png"),
                 Element(new PanelContent(new PanelModel(UsageDecoder.Decode(DemoJson("normal", now)), null, now, RefreshOutcome.NotInstalled), palette)
                 { Background = palette.Solid }), failures);
            // 角色等級卡片（ADR-0020 第 4 節）：這台電腦 40 天、最近 12 天連續
            var levelDays = new Dictionary<string, long>();
            var today = DateOnly.FromDateTime(now.LocalDateTime);
            for (var i = 0; i < 40; i++)
                if (i < 12 || i % 3 != 0) levelDays[LocalCalendar.Key(today.AddDays(-i))] = 300_000;
            Save(Path.Combine(output, $"panel-level-{theme}.png"),
                 Element(new PanelContent(new PanelModel(UsageDecoder.Decode(DemoJson("normal", now)), null, now, null,
                     MascotLevel.From(levelDays, LocalCalendar.Key(today))), palette) { Background = palette.Solid }), failures);
            Save(Path.Combine(output, $"settings-{theme}.png"), SettingsShot(dark, now), failures);
        }
        foreach (var f in failures) Console.Error.WriteLine(f);
        Console.WriteLine($"rendered to {output}; {failures.Count} problem(s)");
        return failures.Count == 0 ? 0 : 1;
    }

    // ---------- 懸浮圓環（ADR-0015「懸浮圓環設計」） ----------

    private const double RingSizeDip = 56;

    /// <summary>
    /// 圓環四種狀態（含沒有資料）、展開的三個方向（往左、往右、貼邊時往下）、貼邊收合、刻度開啟，各畫在淺色與深色桌布上：
    /// <c>ring2/&lt;畫面&gt;-&lt;桌布&gt;-&lt;外觀&gt;.png</c>
    /// </summary>
    private static void RenderRing2(string output, Palette palette, string theme, DateTimeOffset now, List<string> failures)
    {
        Directory.CreateDirectory(output);
        RingContent Content(string scenario) => RingContent.From(UsageDecoder.Decode(DemoJson(scenario, now)), WindowChoice.Automatic, now);
        RingDetails Details(string scenario) => RingDetails.From(UsageDecoder.Decode(DemoJson(scenario, now)), WindowChoice.Automatic, now);
        foreach (var wallpaper in new[] { "light", "dark" })
        {
            var dark = wallpaper == "dark";
            void Shot(string name, BitmapSource bitmap) => Save(Path.Combine(output, $"{name}-{wallpaper}-{theme}.png"), bitmap, failures);
            foreach (var state in new[] { "normal", "too_fast", "critical", "stale" })
            {
                Shot($"ring-{state}", Desk(wallpaper, palette, Content(state), Details(state), RingExpandDirection.Right, RingDock.None, 0, ticks: false));
            }
            Shot("ring-empty", Desk(wallpaper, palette, RingContent.Empty, RingDetails.Empty, RingExpandDirection.Right, RingDock.None, 0, ticks: false));
            Shot("ring-ticks", Desk(wallpaper, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 0, ticks: true));
            Shot("expand-right", Desk(wallpaper, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("expand-left", Desk(wallpaper, palette, Content("too_fast"), Details("too_fast"), RingExpandDirection.Left, RingDock.None, 1, ticks: false));
            Shot("expand-down", Desk(wallpaper, palette, Content("critical"), Details("critical"), RingExpandDirection.Down, RingDock.Left, 1, ticks: false));
            Shot("expand-forecast", Desk(wallpaper, palette, Content("forecast"), Details("forecast"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("expand-half", Desk(wallpaper, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 0.5, ticks: false));
            Shot("dock-tab", Desk(wallpaper, palette, Content("normal"), Details("normal"), RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0));
            Shot("dock-tab-right", Desk(wallpaper, palette, Content("too_fast"), Details("too_fast"), RingExpandDirection.Down, RingDock.Right, 0, ticks: false, reveal: 0));
            Shot("dock-reveal", Desk(wallpaper, palette, Content("normal"), Details("normal"), RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0.6));
            // AI 狀態（ADR-0019）：圓環、展開的膠囊（第二行是 AI 的狀態）、貼邊的標籤
            foreach (var (name, agent) in AgentStates)
            {
                var content = Content("normal").WithAgent(agent);
                Shot($"agent-{name}", Desk(wallpaper, palette, content, Details("normal"), RingExpandDirection.Right, RingDock.None, 0, ticks: false));
                Shot($"agent-{name}-expand", Desk(wallpaper, palette, content, Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            }
            Shot("agent-needs-you-tab", Desk(wallpaper, palette, Content("normal").WithAgent(AgentStates[0].Agent), Details("normal"),
                                             RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0));
            Shot("agent-needs-you-nodata", Desk(wallpaper, palette, RingContent.Empty.WithAgent(AgentStates[0].Agent), RingDetails.Empty,
                                                RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("agent-needs-you-down", Desk(wallpaper, palette, Content("normal").WithAgent(AgentStates[0].Agent), Details("normal"),
                                              RingExpandDirection.Down, RingDock.Left, 1, ticks: false));
            // 其他電腦需要你（ADR-0019 第 2 節）：膠囊第二行前面是那台的名稱
            Shot("agent-remote-expand", Desk(wallpaper, palette,
                                             Content("normal").WithAgent(new RingAgent(AgentKind.Codex, AgentState.NeedsYou, null, "工作 PC")),
                                             Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
        }
    }

    // ---------- 角色（ADR-0015 第 6 節、ADR-0016） ----------

    /// <summary>
    /// 懸浮圖示是角色時：收合（正常、偏高、用完、Codex、工作中、睡著、需要你、角色＋%、外觀）、展開（往右、往左、往下、過場中）、
    /// 貼邊的標籤、等你的脈動，各畫在淺色與深色桌布上：<c>mascot/&lt;畫面&gt;-&lt;桌布&gt;-&lt;外觀&gt;.png</c>。
    /// 狀態機從時間 0 開始擺好，畫固定的那一刻（同 Mac 的 DebugMascot）
    /// </summary>
    private static void RenderMascot(string output, Palette palette, string theme, DateTimeOffset now, List<string> failures)
    {
        Directory.CreateDirectory(output);
        RingContent Content(string scenario) => RingContent.From(UsageDecoder.Decode(DemoJson(scenario, now)), WindowChoice.Automatic, now);
        RingDetails Details(string scenario) => RingDetails.From(UsageDecoder.Decode(DemoJson(scenario, now)), WindowChoice.Automatic, now);
        // 收合時沒有圓底（icons 第 6 部分）：收合的畫面另外放在花俏的桌布上
        foreach (var wallpaper in new[] { "light", "dark", "busy" })
        {
            void Shot(string name, long time, Action<MascotDirector> setup, string scenario = "normal", RingExpandDirection direction = RingExpandDirection.Right,
                      RingDock dock = RingDock.None, double expand = 0, double reveal = 1, string provider = "claude", string? look = null,
                      RingStyle style = RingStyle.Mascot, RingAgent? agent = null, int? level = null, long? pulseAt = null, double scale = Scale)
            {
                var settings = new AppSettings { MascotProvider = provider, MascotLook = look, MascotFollowPointer = false };
                var controller = new MascotController(settings, null, null, Dispatcher.CurrentDispatcher);
                controller.Shot(time, setup, level, pulseAt);
                var face = new MascotFace(controller) { ShowsPercent = style == RingStyle.MascotPercent };
                var content = Content(scenario).WithAgent(agent);
                Save(Path.Combine(output, $"{name}-{wallpaper}-{theme}.png"),
                     Desk(wallpaper, palette, content, Details(scenario), direction, dock, expand, ticks: false, reveal, face, scale), failures);
                controller.Dispose();
            }
            Action<MascotDirector> Open(bool intro = false) => d => d.Open(0, intro);
            Shot("collapsed", 3000, _ => { });
            Shot("collapsed-codex", 3000, _ => { }, provider: "codex");
            Shot("collapsed-high", 3000, d => { d.SetStatus(1, 0, react: false); d.SetMood(MascotMood.Worried); }, scenario: "critical");
            Shot("collapsed-out", 3000, d => { d.SetStatus(2, 0, react: false); d.SetMood(MascotMood.Out); });
            Shot("collapsed-work", 3300, d => d.SetWorking(true, 0));
            Shot("collapsed-sleep", 3300, d => d.SetAgentIdle(true, 0));
            // 背景執行中（ADR-0017 第 7 節）：呼吸加慢速思考泡泡
            Shot("collapsed-think", 3300, d => d.SetBackground(true, 0));
            // 角色合併所有電腦（ADR-0019 第 2 節）：只有其他電腦在工作時想，泡泡旁有小電腦
            Shot("collapsed-remote-think", 3300, d => d.SetRemoteWorking(true, 0));
            Shot("expand-remote-think", 3000, d => { d.Open(0, false); d.SetRemoteWorking(true, 0); }, expand: 1);
            Shot("collapsed-needs-you", 3000, d => d.SetNeedsYou(true, 0), agent: AgentStates[0].Agent);
            Shot("collapsed-percent", 3000, _ => { }, style: RingStyle.MascotPercent);
            Shot("collapsed-pulse", 3800, _ => { }, pulseAt: 3000);
            Shot("collapsed-neon", 3000, _ => { }, look: "X8");
            Shot("collapsed-led", 3000, _ => { }, look: "X9");
            if (wallpaper == "busy")
            {
                Shot("expand-start", 40, d => d.Open(0, false), expand: 1);
                continue;
            }
            // 展開剛開始：膠囊從透明淡入（前 25% 的進度），角色與陰影從原位移過去。
            // 40 ms 時彈簧（190／0.74）的進度約 0.12，膠囊約半透明（Codex C-02：120 ms 已經 0.58、完全不透明）
            Shot("expand-start", 40, Open(), expand: 1);
            Shot("expand-start-left", 40, Open(), direction: RingExpandDirection.Left, expand: 1);
            Shot("expand-right", 3000, Open(), expand: 1, level: 7);
            Shot("expand-left", 3000, Open(), scenario: "too_fast", direction: RingExpandDirection.Left, expand: 1);
            // 貼邊時也是膠囊，朝螢幕內側展開；貼右邊時角色從邊緣移到膠囊左端
            Shot("expand-dock-left", 3000, Open(), scenario: "critical", direction: RingExpandDirection.Right, dock: RingDock.Left, expand: 1, level: 7);
            Shot("expand-dock-right", 3000, Open(), scenario: "critical", direction: RingExpandDirection.Left, dock: RingDock.Right, expand: 1, level: 7);
            Shot("expand-work", 3000, d => { d.Open(0, false); d.SetWorking(true, 0); }, expand: 1);
            Shot("expand-agent", 3000, Open(), expand: 1, agent: AgentStates[0].Agent);
            Shot("intro", 1500, Open(intro: true), expand: 1);
            // 第一次打開的過場：往右、往左、貼左右邊緣，0.3／1.2／2.6／3.9 秒；縮放 125%、150%、200%（實機 DPI）
            foreach (var (tag, direction, dock) in new[] { ("right", RingExpandDirection.Right, RingDock.None), ("left", RingExpandDirection.Left, RingDock.None),
                                                           ("dock-left", RingExpandDirection.Right, RingDock.Left), ("dock-right", RingExpandDirection.Left, RingDock.Right) })
            {
                foreach (var ms in new[] { 300, 1200, 2600, 3900 })
                {
                    Shot($"intro-{tag}-{ms}", ms, Open(intro: true), direction: direction, dock: dock, expand: 1);
                }
            }
            foreach (var dpi in new[] { 125, 150, 200 })
            {
                Shot($"intro-left-1200-dpi{dpi}", 1200, Open(intro: true), direction: RingExpandDirection.Left, expand: 1, scale: dpi / 100.0);
            }
            // 貼邊的標籤：醒著（看向螢幕內側）、工作中、睡著、需要你，左右各一
            foreach (var (side, dock) in new[] { ("", RingDock.Left), ("-right", RingDock.Right) })
            {
                var toward = dock == RingDock.Left ? RingExpandDirection.Right : RingExpandDirection.Left;
                Shot($"dock-tab{side}", 3000, _ => { }, direction: toward, dock: dock, reveal: 0);
                Shot($"dock-tab-work{side}", 3300, d => d.SetWorking(true, 0), direction: toward, dock: dock, reveal: 0);
                Shot($"dock-tab-sleep{side}", 3300, d => d.SetAgentIdle(true, 0), direction: toward, dock: dock, reveal: 0);
                Shot($"dock-tab-needs-you{side}", 3000, d => d.SetNeedsYou(true, 0), direction: toward, dock: dock, reveal: 0, agent: AgentStates[0].Agent);
            }
        }
    }

    private static readonly (string Name, RingAgent Agent)[] AgentStates =
    [
        ("needs-you", new RingAgent(AgentKind.Claude, AgentState.NeedsYou, AgentNeed.Permission)),
        ("done", new RingAgent(AgentKind.Codex, AgentState.Done, null)),
        ("error", new RingAgent(AgentKind.Claude, AgentState.Error, null)),
    ];

    /// <summary>
    /// 一個畫面放在示範桌布上（漸層＋兩團柔和的色塊，看得出半透明的玻璃）。貼邊時桌布左（右）邊就是螢幕邊緣，
    /// 圓環離邊緣 8 DIP（同 RingPlacement.SnapMargin）
    /// </summary>
    private static BitmapSource Desk(string wallpaper, Palette palette, RingContent content, RingDetails details,
                                     RingExpandDirection direction, RingDock dock, double expand, bool ticks, double reveal = 1,
                                     IRingFace? face = null, double scale = Scale)
    {
        const double margin = 20;
        var r = RingShape.DiscRadius(RingSizeDip);
        var shape = (expand > 0 ? RingShape.Shape(direction, dock, RingSizeDip) : new DipRect(-r, -r, r, r)).Inflate(RingShape.Inset);
        double width, height;
        Point center;
        if (dock == RingDock.None)
        {
            width = shape.Width + margin * 2;
            height = shape.Height + margin * 2;
            center = new Point(margin - shape.Left, margin - shape.Top);
        }
        else
        {
            var full = RingShape.Shape(direction, dock, RingSizeDip).Inflate(RingShape.Inset);
            var fromEdge = RingPlacement.SnapMargin + RingSizeDip / 2;
            width = Math.Max(full.Width + RingPlacement.SnapMargin, 2 * fromEdge) + margin;
            height = full.Height + margin * 2;
            center = new Point(dock == RingDock.Left ? fromEdge : width - fromEdge, margin - full.Top);
        }
        var tabCenter = dock == RingDock.Left ? new Point(0, center.Y) : dock == RingDock.Right ? new Point(width, center.Y) : center;
        Rect? visible = dock == RingDock.None ? null
            : new Rect(dock == RingDock.Left ? 0 : width - RingSizeDip / 2, center.Y - RingSizeDip / 2, RingSizeDip / 2, RingSizeDip);
        var scene = new FloatingScene(content, details, palette, face ?? GlassRingFace.Shared, ticks, RingSizeDip, direction, dock,
                                      center, tabCenter, visible, reveal, expand, scale);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            Wallpaper(dc, width, height, wallpaper);
            FloatingRingRenderer.Draw(dc, scene);
            // 看滑鼠時角色在另一層（視窗裡疊在上面）：截圖照同樣的順序畫上去
            if (scene.Face is MascotFace mascot) mascot.Overlay?.Invoke(dc);
        }
        return Bitmap(visual, width, height, scale: scale);
    }

    /// <summary>light、dark，或 busy（花俏的照片風：高彩度的色塊與白色、黑色的細節，收合時沒有圓底的角色要看得清楚）</summary>
    private static void Wallpaper(DrawingContext dc, double width, double height, string wallpaper)
    {
        var bounds = new Rect(0, 0, width, height);
        if (wallpaper == "busy")
        {
            dc.DrawRectangle(new LinearGradientBrush(Color.FromRgb(0xFF, 0xD1, 0x4D), Color.FromRgb(0x2F, 0x9E, 0xE8), 20), null, bounds);
            var colors = new[] { Color.FromRgb(0xF2, 0x4E, 0x6B), Color.FromRgb(0xFF, 0xFF, 0xFF), Color.FromRgb(0x1D, 0x1D, 0x24),
                                 Color.FromRgb(0x5B, 0xD1, 0x7A), Color.FromRgb(0xF5, 0x8A, 0x3D), Color.FromRgb(0x8E, 0x5B, 0xE8) };
            // 固定的條紋與圓點（不用亂數：每次截圖一樣）
            for (var i = 0; i < 14; i++)
            {
                var stripe = new Rect(i * width / 9 - width * 0.2, 0, width / 22, height);
                dc.PushTransform(new RotateTransform(28, stripe.Left + stripe.Width / 2, height / 2));
                dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(150, colors[i % colors.Length].R, colors[i % colors.Length].G, colors[i % colors.Length].B)), null, stripe);
                dc.Pop();
            }
            for (var i = 0; i < 24; i++)
            {
                var c = colors[(i * 5) % colors.Length];
                dc.DrawEllipse(new SolidColorBrush(c), null, new Point(width * ((i * 37) % 100) / 100.0, height * ((i * 61) % 100) / 100.0), 3 + i % 4 * 3, 3 + i % 4 * 3);
            }
            return;
        }
        var dark = wallpaper == "dark";
        dc.DrawRectangle(new LinearGradientBrush(
            dark ? Color.FromRgb(0x18, 0x1E, 0x2E) : Color.FromRgb(0xD9, 0xE4, 0xF2),
            dark ? Color.FromRgb(0x2B, 0x1C, 0x2C) : Color.FromRgb(0xF3, 0xE6, 0xD6), 35), null, bounds);
        void Blob(double x, double y, double radius, Color color)
        {
            var brush = new RadialGradientBrush(color, Color.FromArgb(0, color.R, color.G, color.B));
            dc.DrawEllipse(brush, null, new Point(x, y), radius, radius);
        }
        Blob(width * 0.2, height * 0.85, height * 0.9, dark ? Color.FromArgb(0x70, 0x2E, 0x5E, 0x8C) : Color.FromArgb(0x80, 0x9F, 0xC7, 0xF0));
        Blob(width * 0.85, height * 0.1, height * 0.8, dark ? Color.FromArgb(0x60, 0x8C, 0x3E, 0x5A) : Color.FromArgb(0x70, 0xF5, 0xC2, 0x9A));
    }

    private static BitmapSource Element(FrameworkElement element)
    {
        element.Measure(new Size(PanelContent.PanelWidth, double.PositiveInfinity));
        element.Arrange(new Rect(element.DesiredSize));
        element.UpdateLayout();
        return Bitmap(element, element.ActualWidth, element.ActualHeight);
    }

    /// <summary>
    /// 設定視窗要套 Fluent 主題（視窗的 ThemeMode）：在畫面外顯示、不啟用，畫下內容後關閉。
    /// Fluent 主題的視窗背景是透明的（給 Mica），截圖改墊沒有 Mica 時的純色
    /// </summary>
    private static BitmapSource SettingsShot(bool dark, DateTimeOffset now)
    {
        var settings = new AppSettings { Appearance = dark ? Appearance.Dark : Appearance.Light };
        var window = new SettingsWindow(settings, UsageDecoder.Decode(DemoJson("normal", now)), now, () => { }, new AgentHookInstaller())
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -20000,
            Top = -20000,
            ShowActivated = false,
            ShowInTaskbar = false,
        };
        window.Show();
        window.UpdateLayout();
        // 設定放在捲動區域裡：截圖畫裡面完整的內容
        var content = (FrameworkElement)((ScrollViewer)window.Content).Content;
        // RenderTargetBitmap 依元素的位移（Margin）畫：大小要含邊距，否則右邊與下面被裁掉
        var margin = content.Margin;
        var bitmap = Bitmap(content, content.ActualWidth + margin.Left + margin.Right, content.ActualHeight + margin.Top + margin.Bottom,
                            new Palette(dark).Solid);
        window.Close();
        return bitmap;
    }

    private static BitmapSource Bitmap(Visual visual, double width, double height, Brush? background = null, double scale = Scale)
    {
        var pixelsW = (int)Math.Ceiling(width * scale);
        var pixelsH = (int)Math.Ceiling(height * scale);
        var bitmap = new RenderTargetBitmap(pixelsW, pixelsH, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        if (background is not null)
        {
            var back = new DrawingVisual();
            using (var dc = back.RenderOpen()) dc.DrawRectangle(background, null, new Rect(0, 0, width, height));
            bitmap.Render(back);
        }
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>存 PNG；整張只有一種顏色（CI 的工作階段異常時會畫出空白）就記為問題</summary>
    private static void Save(string path, BitmapSource bitmap, List<string> failures)
    {
        var stride = bitmap.PixelWidth * 4;
        var pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);
        var colors = new HashSet<int>();
        for (var i = 0; i < pixels.Length && colors.Count < 3; i += 4) colors.Add(BitConverter.ToInt32(pixels, i));
        if (colors.Count < 2) failures.Add($"blank: {Path.GetFileName(path)}");
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
#endif
