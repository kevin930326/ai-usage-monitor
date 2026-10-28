using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 設定（ADR-0015 第 5 節）：顯示方式、圓環的額度、大小、透明度、全螢幕時隱藏、開機自動啟動、外觀；AI 狀態的連接與通知（ADR-0019）。
/// 標準控制項用 WPF 的 Fluent 主題（Window.ThemeMode）。改了立刻生效並存檔。
/// </summary>
internal sealed class SettingsWindow : Window
{
    private readonly AppSettings settings;

    public SettingsWindow(AppSettings settings, UsageSnapshot? snapshot, DateTimeOffset now, Action changed, AgentHookInstaller hooks)
    {
        this.settings = settings;
        Title = "AI Usage Monitor 設定";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ApplyTheme(settings.Appearance);
        Content = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = SystemParameters.WorkArea.Height * 0.85,
            Content = new SettingsView(settings, snapshot, now, () =>
            {
                ApplyTheme(settings.Appearance);
                changed();
            }, hooks),
        };
    }

    /// <summary>系統的深淺色或透明效果改變時（AppHost 收到 ImmersiveColorSet）：重新套用主題與背景</summary>
    public void RefreshLook() => ApplyTheme(settings.Appearance);

    private void ApplyTheme(Appearance appearance)
    {
        ThemeMode = appearance switch
        {
            Appearance.Light => ThemeMode.Light,
            Appearance.Dark => ThemeMode.Dark,
            _ => SystemLook.ForcedDark is { } dark ? (dark ? ThemeMode.Dark : ThemeMode.Light) : ThemeMode.System,
        };
        // Fluent 主題的視窗背景是透明的（給 Mica）：Windows 10 或透明效果關閉時改用和面板相同的純色
        if (SystemLook.SupportsBackdrop && SystemLook.TransparencyEnabled) ClearValue(BackgroundProperty);
        else Background = new Palette(SystemLook.IsDark(appearance)).Solid;
    }
}

/// <summary>設定的內容（截圖也用這個）</summary>
internal sealed class SettingsView : StackPanel
{
    private readonly AppSettings settings;
    private readonly Action changed;
    private readonly AgentHookInstaller hooks;
    private readonly StackPanel hookRows = new();
    private bool loading = true;

    public SettingsView(AppSettings settings, UsageSnapshot? snapshot, DateTimeOffset now, Action changed, AgentHookInstaller hooks)
    {
        this.settings = settings;
        this.changed = changed;
        this.hooks = hooks;
        Margin = new Thickness(24, 20, 24, 24);
        TextElement.SetFontFamily(this, SystemLook.Font);

        Section("懸浮圓環與系統匣");
        Row("顯示方式", Choice(
            [("懸浮圓環和系統匣圖示", DisplayMode.Both), ("只有懸浮圓環", DisplayMode.Ring), ("只有系統匣圖示", DisplayMode.Tray)],
            settings.DisplayMode, v => settings.DisplayMode = v));
        var windows = new List<(string, string)> { ("自動（剩餘最少的）", WindowChoice.Automatic.RawValue) };
        if (snapshot is not null)
        {
            foreach (var key in snapshot.OrderedProviderKeys)
            {
                foreach (var w in snapshot.Providers[key].VisibleWindows) windows.Add((new ProviderWindow(key, w).DisplayName, $"{key}/{w.Id}"));
            }
        }
        // 指定的額度暫時不在資料裡（服務錯誤）時仍列出，圓環改用剩餘最少的
        if (!settings.RingWindow.IsAutomatic && windows.All(w => w.Item2 != settings.RingWindow.RawValue))
        {
            windows.Add(($"{settings.RingWindow.RawValue}（目前沒有資料）", settings.RingWindow.RawValue));
        }
        Row("圓環顯示的額度", Choice(windows, settings.RingWindow.RawValue, v => settings.RingWindow = WindowChoice.Parse(v)));
        Row("圓環大小", Choice([("小", RingSize.Small), ("中", RingSize.Medium), ("大", RingSize.Large)], settings.RingSize, v => settings.RingSize = v));
        Row("圓環透明度", OpacitySlider());
        Children.Add(Check("全螢幕的 App 在同一個螢幕時隱藏圓環", settings.HideInFullscreen, v => settings.HideInFullscreen = v));
        Children.Add(Check("貼在螢幕左右邊緣時收成半圓的小標籤", settings.DockToEdge, v => settings.DockToEdge = v));
        Children.Add(Check("圓環外圍顯示刻度（這個額度週期過了多少時間）", settings.RingTicks, v => settings.RingTicks = v));

        Section("一般");
        Children.Add(Check("登入 Windows 時自動啟動", settings.LaunchAtLogin, v => settings.LaunchAtLogin = v));
        Row("外觀", Choice([("跟隨系統", Appearance.System), ("淺色", Appearance.Light), ("深色", Appearance.Dark)],
                         settings.Appearance, v => settings.Appearance = v));

        Section("AI 狀態");
        Children.Add(Note("連接後，Claude Code 與 Codex 每到一個時間點（開始、送出提示、執行工具、需要你、完成）會通知這個 App，圓環就會在 AI 需要你時亮起琥珀色外框、完成或出錯時顯示徽章。"
                          + "只傳事件種類與工作階段的雜湊，不傳資料夾名稱、提示、指令或檔案內容；App 沒在執行時 hook 立刻結束、什麼都不寫。"));
        Children.Add(hookRows);
        FillHooks();
        Row("需要你時通知", Choice([.. AppSettings.NeedsYouSecondChoices.Select(s => (s == 0 ? "關閉" : $"{s} 秒後", s))],
                                   settings.AgentNeedsYouSeconds, v => settings.AgentNeedsYouSeconds = v));
        Row("長任務完成時通知", Choice([.. AppSettings.LongTaskMinuteChoices.Select(m => (m == 0 ? "關閉" : $"跑超過 {m} 分鐘", m))],
                                      settings.AgentLongTaskMinutes, v => settings.AgentLongTaskMinutes = v));
        Children.Add(Note("以系統匣圖示發出 Windows 通知，會遵守「專注」與勿擾；顯示方式選了「只有懸浮圓環」時沒有系統匣圖示，不會通知。"
                          + "通知只寫哪個 AI、要你做什麼，不寫資料夾名稱，也沒有任何按鈕（不能從這裡允許或拒絕 AI 的操作）。"));

        Section("資料");
        Children.Add(new TextBlock
        {
            Text = $"讀取 {DataPaths.Usage}（收集器以 install-task.ps1 -WithQuota 寫入）。App 不連網、不持有密鑰。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
            FontSize = 12,
        });
        if (snapshot is not null)
        {
            Children.Add(new TextBlock { Text = RingText.Updated(snapshot, now, TimeZoneInfo.Local), Opacity = 0.7, FontSize = 12, Margin = new Thickness(0, 4, 0, 0) });
        }
        loading = false;
    }

    /// <summary>每個 AI 一行：名稱、狀態、按鈕；下面是會改哪個檔案與上一次的結果</summary>
    private void FillHooks()
    {
        hookRows.Children.Clear();
        foreach (var ai in new[] { AgentKind.Claude, AgentKind.Codex })
        {
            var item = hooks.Current(ai);
            var grid = new Grid { Margin = new Thickness(0, 8, 0, 2) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = AgentText.Name(ai), FontWeight = FontWeights.SemiBold });
            text.Children.Add(new TextBlock { Text = StateText(item), Opacity = 0.7, FontSize = 12, TextWrapping = TextWrapping.Wrap });
            grid.Children.Add(text);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            void Add(string label, Action action)
            {
                var button = new Button { Content = label, Margin = new Thickness(6, 0, 0, 0), MinWidth = 64 };
                System.Windows.Automation.AutomationProperties.SetName(button, $"{label} {AgentText.Name(ai)}");
                button.Click += (_, _) =>
                {
                    action();
                    FillHooks();
                };
                buttons.Children.Add(button);
            }
            switch (item.State)
            {
                case AgentHookInstaller.State.NotInstalled:
                    if (AgentHookInstaller.UsablePath) Add("連接", () => hooks.Connect(ai));
                    break;
                case AgentHookInstaller.State.NeedsRepair:
                    if (AgentHookInstaller.UsablePath) Add("修好", () => hooks.Connect(ai));
                    Add("移除", () => hooks.Disconnect(ai));
                    break;
                case AgentHookInstaller.State.Installed:
                    Add("移除", () => hooks.Disconnect(ai));
                    break;
            }
            Grid.SetColumn(buttons, 1);
            grid.Children.Add(buttons);
            hookRows.Children.Add(grid);
            var events = string.Join("、", AgentNames.Installed(ai).Select(AgentNames.Name));
            hookRows.Children.Add(Note($"會改 {AgentHookInstaller.DisplayPath(ai)}：在 {events} 加上這個 App 的 hook。改之前先備份原檔；只加、只刪自己的項目，"
                                       + "其他程式的 hook 照樣保留（縮排會變成兩格）。"));
            if (ai == AgentKind.Codex)
            {
                hookRows.Children.Add(Note(hooks.CodexDisabled
                    ? "Codex 的 config.toml 有 [features] hooks = false，hook 不會執行。"
                    : "第一次連接或修好後，在 Codex 裡執行 /hooks 信任這個 hook 才會生效。"));
            }
            if (item.Message is { } message) hookRows.Children.Add(Note(message, 1));
        }
        if (!AgentHookInstaller.UsablePath)
        {
            hookRows.Children.Add(Note("App 的位置含有引號、%、^、& 等字元，沒辦法放進設定檔；把 App 裝到其他資料夾後再連接。", 1));
        }
    }

    private static string StateText(AgentHookInstaller.Item item) => item.State switch
    {
        AgentHookInstaller.State.NotInstalled => "沒有連接",
        AgentHookInstaller.State.Installed => "已連接",
        AgentHookInstaller.State.NeedsRepair when item.Status is { WrongPath: true } => "App 被移動過或少了 aum-hook.exe，需要修好",
        AgentHookInstaller.State.NeedsRepair => $"少了 {item.Status?.Missing.Count ?? 0} 個事件，需要修好",
        _ => "設定檔不是合法的 JSON 或格式不同，沒辦法連接；修好檔案後再打開設定",
    };

    private static TextBlock Note(string text, double opacity = 0.7) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Opacity = opacity,
        FontSize = 12,
        Margin = new Thickness(0, 2, 0, 2),
    };

    private void Changed()
    {
        if (!loading) changed();
    }

    private void Section(string title)
    {
        Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, Children.Count == 0 ? 0 : 20, 0, 8),
        });
    }

    private void Row(string label, FrameworkElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(text);
        Grid.SetColumn(control, 1);
        System.Windows.Automation.AutomationProperties.SetName(control, label);
        grid.Children.Add(control);
        Children.Add(grid);
    }

    private ComboBox Choice<T>(IReadOnlyList<(string Label, T Value)> options, T selected, Action<T> set)
    {
        var box = new ComboBox();
        foreach (var (label, _) in options) box.Items.Add(label);
        var index = options.ToList().FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, selected));
        box.SelectedIndex = Math.Max(index, 0);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex < 0) return;
            set(options[box.SelectedIndex].Value);
            Changed();
        };
        return box;
    }

    private CheckBox Check(string label, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 6, 0, 2) };
        box.Click += (_, _) =>
        {
            set(box.IsChecked == true);
            Changed();
        };
        return box;
    }

    private FrameworkElement OpacitySlider()
    {
        var panel = new DockPanel();
        var value = new TextBlock { Width = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(value, Dock.Right);
        var slider = new Slider
        {
            Minimum = AppSettings.MinimumOpacity * 100,
            Maximum = 100,
            Value = settings.Opacity * 100,
            SmallChange = 5,
            LargeChange = 10,
            TickFrequency = 5,
            IsSnapToTickEnabled = true,
            VerticalAlignment = VerticalAlignment.Center,
        };
        void Show() => value.Text = $"{Math.Round(slider.Value).ToString(CultureInfo.InvariantCulture)}%";
        Show();
        // 拖動時每一格都會觸發：停下 300 ms 後才存檔與套用
        var settle = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(300) };
        settle.Tick += (_, _) =>
        {
            settle.Stop();
            Changed();
        };
        slider.ValueChanged += (_, _) =>
        {
            Show();
            settings.Opacity = slider.Value / 100;
            settle.Stop();
            settle.Start();
        };
        panel.Children.Add(value);
        panel.Children.Add(slider);
        return panel;
    }
}
