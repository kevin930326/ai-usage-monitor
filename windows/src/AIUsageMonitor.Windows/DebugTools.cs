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
                Shot($"ring-{state}", Desk(dark, palette, Content(state), Details(state), RingExpandDirection.Right, RingDock.None, 0, ticks: false));
            }
            Shot("ring-empty", Desk(dark, palette, RingContent.Empty, RingDetails.Empty, RingExpandDirection.Right, RingDock.None, 0, ticks: false));
            Shot("ring-ticks", Desk(dark, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 0, ticks: true));
            Shot("expand-right", Desk(dark, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("expand-left", Desk(dark, palette, Content("too_fast"), Details("too_fast"), RingExpandDirection.Left, RingDock.None, 1, ticks: false));
            Shot("expand-down", Desk(dark, palette, Content("critical"), Details("critical"), RingExpandDirection.Down, RingDock.Left, 1, ticks: false));
            Shot("expand-forecast", Desk(dark, palette, Content("forecast"), Details("forecast"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("expand-half", Desk(dark, palette, Content("normal"), Details("normal"), RingExpandDirection.Right, RingDock.None, 0.5, ticks: false));
            Shot("dock-tab", Desk(dark, palette, Content("normal"), Details("normal"), RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0));
            Shot("dock-tab-right", Desk(dark, palette, Content("too_fast"), Details("too_fast"), RingExpandDirection.Down, RingDock.Right, 0, ticks: false, reveal: 0));
            Shot("dock-reveal", Desk(dark, palette, Content("normal"), Details("normal"), RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0.6));
            // AI 狀態（ADR-0019）：圓環、展開的膠囊（第二行是 AI 的狀態）、貼邊的標籤
            foreach (var (name, agent) in AgentStates)
            {
                var content = Content("normal").WithAgent(agent);
                Shot($"agent-{name}", Desk(dark, palette, content, Details("normal"), RingExpandDirection.Right, RingDock.None, 0, ticks: false));
                Shot($"agent-{name}-expand", Desk(dark, palette, content, Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            }
            Shot("agent-needs-you-tab", Desk(dark, palette, Content("normal").WithAgent(AgentStates[0].Agent), Details("normal"),
                                             RingExpandDirection.Down, RingDock.Left, 0, ticks: false, reveal: 0));
            Shot("agent-needs-you-nodata", Desk(dark, palette, RingContent.Empty.WithAgent(AgentStates[0].Agent), RingDetails.Empty,
                                                RingExpandDirection.Right, RingDock.None, 1, ticks: false));
            Shot("agent-needs-you-down", Desk(dark, palette, Content("normal").WithAgent(AgentStates[0].Agent), Details("normal"),
                                              RingExpandDirection.Down, RingDock.Left, 1, ticks: false));
            // 其他電腦需要你（ADR-0019 第 2 節）：膠囊第二行前面是那台的名稱
            Shot("agent-remote-expand", Desk(dark, palette,
                                             Content("normal").WithAgent(new RingAgent(AgentKind.Codex, AgentState.NeedsYou, null, "工作 PC")),
                                             Details("normal"), RingExpandDirection.Right, RingDock.None, 1, ticks: false));
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
    private static BitmapSource Desk(bool darkWallpaper, Palette palette, RingContent content, RingDetails details,
                                     RingExpandDirection direction, RingDock dock, double expand, bool ticks, double reveal = 1)
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
        var scene = new FloatingScene(content, details, palette, GlassRingFace.Shared, ticks, RingSizeDip, direction, dock,
                                      center, tabCenter, visible, reveal, expand, Scale);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            Wallpaper(dc, width, height, darkWallpaper);
            FloatingRingRenderer.Draw(dc, scene);
        }
        return Bitmap(visual, width, height);
    }

    private static void Wallpaper(DrawingContext dc, double width, double height, bool dark)
    {
        var bounds = new Rect(0, 0, width, height);
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

    private static BitmapSource Bitmap(Visual visual, double width, double height, Brush? background = null)
    {
        var pixelsW = (int)Math.Ceiling(width * Scale);
        var pixelsH = (int)Math.Ceiling(height * Scale);
        var bitmap = new RenderTargetBitmap(pixelsW, pixelsH, 96 * Scale, 96 * Scale, PixelFormats.Pbgra32);
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
