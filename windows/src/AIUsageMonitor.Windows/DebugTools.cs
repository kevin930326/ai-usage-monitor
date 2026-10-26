#if DEBUG
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
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
    public static readonly string[] Scenarios = ["normal", "too_fast", "critical", "stale", "error", "single", "none"];

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
                Save(Path.Combine(output, $"ring-{state}-{theme}.png"), RingVisual(content, palette, 56), failures);
                Save(Path.Combine(output, $"tray-{state}-{theme}.png"), TrayIcon.RenderBitmap(content, palette, 64), failures);
            }
            Save(Path.Combine(output, $"ring-empty-{theme}.png"), RingVisual(RingContent.Empty, palette, 56), failures);
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

    /// <summary>圓環放在棋盤格上（看得出透明的部分）</summary>
    private static BitmapSource RingVisual(RingContent content, Palette palette, double size)
    {
        var margin = 12;
        var total = size + margin * 2;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var light = new SolidColorBrush(Color.FromRgb(0xCC, 0xCC, 0xCC));
            var lighter = new SolidColorBrush(Color.FromRgb(0xEE, 0xEE, 0xEE));
            for (var y = 0; y < total; y += 8)
            {
                for (var x = 0; x < total; x += 8)
                {
                    dc.DrawRectangle((x / 8 + y / 8) % 2 == 0 ? light : lighter, null, new Rect(x, y, 8, 8));
                }
            }
            dc.PushTransform(new TranslateTransform(margin, margin));
            RingDrawing.DrawFloating(dc, content, size, palette);
            dc.Pop();
        }
        return Bitmap(visual, total, total);
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
        var window = new SettingsWindow(settings, UsageDecoder.Decode(DemoJson("normal", now)), now, () => { })
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -20000,
            Top = -20000,
            ShowActivated = false,
            ShowInTaskbar = false,
        };
        window.Show();
        window.UpdateLayout();
        var content = (FrameworkElement)window.Content;
        var bitmap = Bitmap(content, content.ActualWidth, content.ActualHeight, new Palette(dark).Solid);
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
