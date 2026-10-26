using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 把各部分接起來：資料（UsageStore）、懸浮圓環、系統匣、全螢幕偵測、面板與設定。
/// 整個 App 只有一個每分鐘的計時器（對齊整分鐘）：更新圓環與系統匣（內容沒變不重畫）、面板開著時更新倒數。
/// </summary>
internal sealed class AppHost : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly AppSettings settings;
    private readonly UsageStore store;
    private readonly TrayIcon tray;
    private readonly FullscreenWatcher fullscreen;
    private readonly CollectorTrigger trigger;
    private readonly DispatcherTimer minute;
    private RingWindow? ring;
    private PanelWindow? panel;
    private SettingsWindow? settingsWindow;
    private RefreshOutcome? hint;
    private DateTimeOffset now = Clock.Now;
    private bool disposed;

    public AppHost(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        settings = SettingsFile.Load();
        store = new UsageStore(dispatcher);
        tray = new TrayIcon();
        trigger = new CollectorTrigger(settings);
        fullscreen = new FullscreenWatcher(dispatcher, () => ring?.Handle ?? IntPtr.Zero);
        minute = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
        minute.Tick += (_, _) => OnMinute();
    }

    private Palette AppPalette => new(SystemLook.IsDark(settings.Appearance));
    private Palette TrayPalette => new(SystemLook.TaskbarIsDark);

    private RingContent Content => RingContent.From(store.Snapshot, settings.RingWindow, now);

    public void Start()
    {
        // 第一次執行時依設定寫入開機自動啟動（安裝腳本也會依同一個設定寫）
        if (settings.LaunchAtLogin != Autostart.IsEnabled) Autostart.Set(settings.LaunchAtLogin);
        store.Changed += () =>
        {
            hint = null;
            Refresh();
        };
        tray.DoubleClicked += () => TogglePanel(fromTray: true);
        tray.ContextMenuRequested += (_, _) => ShowMenu(fromTray: true);
        tray.SettingsChanged += () =>
        {
            ApplyLook();
        };
        tray.DisplayChanged += () => dispatcher.BeginInvoke(PlaceRing, DispatcherPriority.Background);
        fullscreen.Changed += ApplyVisibility;
        fullscreen.ForegroundChanged += () => ring?.BringToTop();
        store.Start();
        ApplyDisplayMode();
        ScheduleMinute();
    }

    // ---------- 計時器 ----------

    private void ScheduleMinute()
    {
        // 對齊下一個整分鐘，之後每 60 秒
        var local = DateTimeOffset.Now;
        var wait = TimeSpan.FromSeconds(60 - local.Second) - TimeSpan.FromMilliseconds(local.Millisecond) + TimeSpan.FromMilliseconds(50);
        minute.Interval = wait;
        minute.Start();
    }

    private void OnMinute()
    {
        if (minute.Interval != TimeSpan.FromMinutes(1)) minute.Interval = TimeSpan.FromMinutes(1);
        store.Poll();
        Refresh();
    }

    // ---------- 畫面 ----------

    private void Refresh()
    {
        now = Clock.Now;
        var content = Content;
        ring?.SetContent(content, AppPalette);
        tray.Update(content, TrayPalette);
        panel?.SetModel(Model);
    }

    private PanelModel Model => new(store.Snapshot, store.Error, now, hint);

    /// <summary>外觀改變（設定或系統的深淺色）：圓環、系統匣、面板重畫；面板的材質在下次打開時套用</summary>
    private void ApplyLook()
    {
        Refresh();
        // 面板的材質與深淺色在建立時決定：下次打開時套用
        panel?.SafeClose();
    }

    private void ApplyDisplayMode()
    {
        if (settings.ShowsRing && ring is null)
        {
            var size = AppSettings.RingDip(settings.RingSize);
            ring = new RingWindow(size, settings.Opacity);
            ring.Clicked += () => TogglePanel(fromTray: false);
            ring.DragEnded += OnDragEnded;
            ring.MouseRightButtonUp += (_, e) =>
            {
                e.Handled = true;
                ShowMenu(fromTray: false);
            };
            ring.SetContent(Content, AppPalette);
            _ = ring.Handle;
            PlaceRing();
            fullscreen.Start();
        }
        else if (!settings.ShowsRing && ring is not null)
        {
            fullscreen.Stop();
            ring.Close();
            ring = null;
        }
        if (ring is not null)
        {
            ring.Opacity = settings.Opacity;
            if (Math.Abs(ring.Width - AppSettings.RingDip(settings.RingSize)) > 0.1)
            {
                ring.SetSize(AppSettings.RingDip(settings.RingSize));
                PlaceRing();
            }
            if (settings.HideInFullscreen) fullscreen.Start();
            else fullscreen.Stop();
        }
        if (settings.ShowsTray) tray.Show(Content, TrayPalette);
        else tray.Hide();
        ApplyVisibility();
    }

    private void ApplyVisibility()
    {
        if (ring is null) return;
        var hide = settings.HideInFullscreen && fullscreen.IsFullscreen;
        if (hide)
        {
            if (ring.IsVisible) ring.Hide();
            panel?.SafeClose();
        }
        else if (!ring.IsVisible)
        {
            ring.Show();
            ring.BringToTop();
        }
    }

    /// <summary>依記住的位置放圓環（啟動、顯示設定改變、大小改變）；一律在看得見的工作區內</summary>
    private void PlaceRing()
    {
        if (ring is null) return;
        var monitors = NativeMethods.Monitors();
        if (monitors.Count == 0) return;
        var dip = AppSettings.RingDip(settings.RingSize);
        var (rect, _) = RingPlacement.Restore(settings.Positions, monitors, m => (int)Math.Round(dip * m.Scale));
        ring.MoveTo(rect);
    }

    private void OnDragEnded(PixelRect rect)
    {
        if (ring is null) return;
        var monitors = NativeMethods.Monitors();
        if (monitors.Count == 0) return;
        var monitor = RingPlacement.MonitorOf(rect, monitors);
        var snapped = RingPlacement.Snap(rect, monitor);
        ring.MoveTo(snapped);
        settings.Positions = RingPlacement.Remember(settings.Positions, ring.Rect, monitor, DateTimeOffset.Now);
        SettingsFile.Save(settings);
    }

    // ---------- 面板 ----------

    public void ShowPanel() => OpenPanel(fromTray: ring is null || !ring.IsVisible);

    public void HidePanel() => panel?.SafeClose();

    private void TogglePanel(bool fromTray)
    {
        if (panel is not null)
        {
            panel.SafeClose();
            return;
        }
        OpenPanel(fromTray);
    }

    private void OpenPanel(bool fromTray)
    {
        if (panel is not null)
        {
            panel.Activate();
            return;
        }
        now = Clock.Now;
        var window = new PanelWindow(Model, AppPalette);
        window.RefreshRequested += () => _ = RefreshAsync();
        window.SettingsRequested += () =>
        {
            window.SafeClose();
            OpenSettings();
        };
        window.QuitRequested += Quit;
        window.Closed += (_, _) =>
        {
            if (panel == window) panel = null;
        };
        panel = window;
        // 先建立視窗量出大小，再放到圓環旁邊或系統匣的角落
        window.Left = -10000;
        window.Top = -10000;
        window.ShowActivated = true;
        window.Show();
        window.UpdateLayout();
        var hwnd = new WindowInteropHelper(window).Handle;
        NativeMethods.GetCursorPos(out var cursor);
        var monitor = NativeMethods.Monitor(fromTray || ring is null
            ? NativeMethods.MonitorFromPoint(cursor, NativeMethods.MONITOR_DEFAULTTONEAREST)
            : NativeMethods.MonitorFromWindow(ring.Handle, NativeMethods.MONITOR_DEFAULTTONEAREST));
        if (monitor is not null)
        {
            // 移到 DPI 不同的螢幕時 WPF 會改大小：放兩次，第二次用新的大小
            for (var pass = 0; pass < 2; pass++)
            {
                var size = NativeMethods.WindowRect(hwnd);
                var target = fromTray || ring is null
                    ? PanelPlacement.NearTray(cursor.X, cursor.Y, size.Width, size.Height, monitor)
                    : PanelPlacement.NextToRing(ring.Rect, size.Width, size.Height, monitor);
                window.PlaceAt(target);
                window.UpdateLayout();
                if (NativeMethods.WindowRect(hwnd) == target) break;
            }
        }
        window.Activate();
        NativeMethods.SetForegroundWindow(hwnd);
        window.PlayAppear();
    }

    private async System.Threading.Tasks.Task RefreshAsync()
    {
        store.Reload();
        hint = await trigger.TriggerAsync();
        panel?.SetModel(Model);
    }

    // ---------- 選單與設定 ----------

    /// <summary>右鍵選單（圓環與系統匣相同）：打開面板、立即更新、設定、隱藏／顯示圓環、結束</summary>
    private void ShowMenu(bool fromTray)
    {
        var menu = new ContextMenu();
        void Add(string header, Action action)
        {
            var item = new MenuItem { Header = header };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("打開面板", () => OpenPanel(fromTray));
        Add("立即更新", () => _ = RefreshAsync());
        Add("設定…", OpenSettings);
        menu.Items.Add(new Separator());
        if (settings.ShowsRing)
        {
            // 隱藏圓環＝只留系統匣（一定還有地方可以操作）
            Add("隱藏圓環", () => SetDisplayMode(DisplayMode.Tray));
        }
        else
        {
            Add("顯示圓環", () => SetDisplayMode(DisplayMode.Both));
        }
        Add("結束", Quit);
        if (fromTray)
        {
            // 選單要能在點其他地方時收起：先讓隱藏的系統匣視窗成為前景
            NativeMethods.SetForegroundWindow(tray.Handle);
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        }
        else
        {
            menu.PlacementTarget = ring;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        }
        menu.IsOpen = true;
    }

    private void SetDisplayMode(DisplayMode mode)
    {
        settings.DisplayMode = mode;
        SettingsFile.Save(settings);
        ApplyDisplayMode();
    }

    private void OpenSettings()
    {
        if (settingsWindow is not null)
        {
            settingsWindow.Activate();
            return;
        }
        settingsWindow = new SettingsWindow(settings, store.Snapshot, Clock.Now, OnSettingsChanged);
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show();
        settingsWindow.Activate();
    }

    private void OnSettingsChanged()
    {
        SettingsFile.Save(settings);
        if (settings.LaunchAtLogin != Autostart.IsEnabled) Autostart.Set(settings.LaunchAtLogin);
        ApplyDisplayMode();
        ApplyLook();
    }

    public void Quit()
    {
        Dispose();
        Application.Current.Shutdown();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        minute.Stop();
        fullscreen.Dispose();
        store.Dispose();
        tray.Dispose();
        panel?.SafeClose();
        settingsWindow?.Close();
        ring?.Close();
        ring = null;
    }
}
