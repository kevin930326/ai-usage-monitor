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
/// 設定（ADR-0015 第 5 節）：顯示方式、圓環的額度、大小、透明度、全螢幕時隱藏、開機自動啟動、外觀。
/// 標準控制項用 WPF 的 Fluent 主題（Window.ThemeMode）。改了立刻生效並存檔。
/// </summary>
internal sealed class SettingsWindow : Window
{
    public SettingsWindow(AppSettings settings, UsageSnapshot? snapshot, DateTimeOffset now, Action changed)
    {
        Title = "AI Usage Monitor 設定";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ApplyTheme(settings.Appearance);
        Content = new SettingsView(settings, snapshot, now, () =>
        {
            ApplyTheme(settings.Appearance);
            changed();
        });
    }

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
    private bool loading = true;

    public SettingsView(AppSettings settings, UsageSnapshot? snapshot, DateTimeOffset now, Action changed)
    {
        this.settings = settings;
        this.changed = changed;
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

        Section("一般");
        Children.Add(Check("登入 Windows 時自動啟動", settings.LaunchAtLogin, v => settings.LaunchAtLogin = v));
        Row("外觀", Choice([("跟隨系統", Appearance.System), ("淺色", Appearance.Light), ("深色", Appearance.Dark)],
                         settings.Appearance, v => settings.Appearance = v));

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
