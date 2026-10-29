using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 把各部分接起來：資料（UsageStore）、AI 狀態（AgentMonitor）、懸浮圓環、系統匣、全螢幕偵測、面板與設定。
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
    private readonly AgentMonitor agents;
    private readonly AgentHookInstaller hooks = new();
    /// <summary>懸浮圖示是角色時的狀態與畫法（樣式是圓環時不顯示，計時器全停）</summary>
    private readonly MascotController mascot;
    private readonly MascotFace mascotFace;
    private RingWindow? ring;
    private PanelWindow? panel;
    private SettingsWindow? settingsWindow;
    private RefreshOutcome? hint;
    private DateTimeOffset now = Clock.Now;
    /// <summary>角色等級（面板打開時在背景讀，讀不到時沿用上次的值）與這次執行看過的每一天（level.json 讀不到時也不倒退）</summary>
    private MascotLevel? level;
    private Dictionary<string, long> levelDays = [];
    private bool levelLoading;
    /// <summary>面板是從系統匣打開的（等級卡片晚一點加進來、面板變高時，照同樣的方式重新放）</summary>
    private bool panelFromTray;
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
        agents = new AgentMonitor(dispatcher, DataPaths.Home, settings);
        mascot = new MascotController(settings, agents, store, dispatcher);
        mascotFace = new MascotFace(mascot);
    }

    private Palette AppPalette => new(SystemLook.IsDark(settings.Appearance));
    private Palette TrayPalette => new(SystemLook.TaskbarIsDark);

    private RingContent Content => RingContent.From(store.Snapshot, settings.RingWindow, now)
        .WithAgent(Hinted(RingAgent.From(agents.Sessions, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), agents.Remote,
                                  merged: settings.RingStyle != RingStyle.Ring, seenErrors: agents.SeenRemoteErrors)));

    /// <summary>點了跳不過去的那一列（ADR-0017 第 10 節）：2 秒內第二行換成提示</summary>
    private (RingAgent Agent, string Text)? jumpHint;
    private DispatcherTimer? jumpHintTimer;

    private RingAgent? Hinted(RingAgent? agent) =>
        agent is not null && jumpHint is { } hint && hint.Agent.Session == agent.Session && hint.Agent.Device == agent.Device
            ? agent with { Hint = hint.Text }
            : agent;

    /// <summary>點了膠囊上 AI 那一列：這台的跳回那個工作階段；其他電腦的只提示在哪台</summary>
    private void JumpTo(RingAgent agent)
    {
        if (agent.Session is not { } session)
        {
            ShowJumpHint(agent, $"在{agent.Device}上");
            return;
        }
        AgentJumper.Jump(agents, agent.Ai, session, dispatcher, ok =>
        {
            if (!ok) ShowJumpHint(agent, "找不到這個工作階段的視窗");
        });
    }

    private void ShowJumpHint(RingAgent agent, string text)
    {
        jumpHint = (agent, text);
        Refresh();
        jumpHintTimer?.Stop();
        jumpHintTimer = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) =>
        {
            jumpHintTimer?.Stop();
            jumpHint = null;
            Refresh();
        }, dispatcher);
    }
    private RingDetails Details => RingDetails.From(store.Snapshot, settings.RingWindow, now);

    public void Start()
    {
        // 第一次執行時依設定寫入開機自動啟動（安裝腳本也會依同一個設定寫）
        if (settings.LaunchAtLogin != Autostart.IsEnabled) Autostart.Set(settings.LaunchAtLogin);
        store.Changed += () =>
        {
            hint = null;
            Refresh();
            mascot.UpdateStatus();
        };
        // 展開就讀一次等級（ADR-0020 第 4 節）；升級時角色歡呼
        mascot.Opened += LoadLevel;
        // Windows 的「顯示動畫」改了：角色的動畫程度跟著換（關閉時用「簡單」）
        SystemParameters.StaticPropertyChanged += OnSystemParameter;
        tray.DoubleClicked += () => TogglePanel(fromTray: true);
        tray.BalloonClicked += () =>
        {
            if (agents.LastNotice is { } notice) AgentJumper.Jump(agents, notice.Ai, notice.Session, dispatcher, _ => { });
        };
        tray.ContextMenuRequested += (_, _) => ShowMenu(fromTray: true);
        tray.SettingsChanged += () =>
        {
            ApplyLook();
        };
        tray.DisplayChanged += () => dispatcher.BeginInvoke(PlaceRing, DispatcherPriority.Background);
        fullscreen.Changed += ApplyVisibility;
        fullscreen.ForegroundChanged += () =>
        {
            ring?.BringToTop();
            // 別的程序成為前景（只會收到其他程序的事件）：面板若沒能成為作用中視窗就收不到 Deactivated，在這裡收起
            if (panel is { IsActive: false }) panel.SafeClose();
        };
        fullscreen.Start();
        agents.Changed += RefreshIndicators;
        agents.Changed += mascot.AgentStateChanged;
        agents.Finished += mascot.AgentFinished;
        agents.Notify += (title, body) => tray.Notify(title, body);
        agents.Start();
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
        agents.Tick();
        Refresh();
        mascot.UpdateStatus();
    }

    private void OnSystemParameter(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SystemParameters.ClientAreaAnimation) or nameof(SystemParameters.HighContrast)) mascot.MotionChanged();
    }

    /// <summary>aum-hook.exe 寫好事件檔、觸發了具名事件</summary>
    public void AgentEvent() => agents.Pump();

    // ---------- 畫面 ----------

    private void Refresh()
    {
        now = Clock.Now;
        var content = Content;
        ring?.SetContent(content, Details, AppPalette);
        tray.Update(content, TrayPalette);
        panel?.SetModel(Model);
    }

    /// <summary>AI 狀態改變：只更新圓環與系統匣（內容沒變不重畫）。面板不重建，捲動位置與焦點不受工具事件影響（Codex C-04）</summary>
    private void RefreshIndicators()
    {
        var content = Content;
        ring?.SetContent(content, Details, AppPalette);
        tray.Update(content, TrayPalette);
    }

    private PanelModel Model => new(store.Snapshot, store.Error, now, hint, level);

    /// <summary>
    /// 面板打開時讀這台電腦的每日主數字（history.sqlite3 的 record_days，唯讀、讀完就關），併進 level.json 後算等級
    /// （ADR-0020 第 1、4 節）。在背景執行緒做，讀完再更新面板；同時只有一個。
    /// </summary>
    private void LoadLevel()
    {
        if (levelLoading) return;
        levelLoading = true;
        var known = levelDays;
        var today = LocalCalendar.Key(DateOnly.FromDateTime(Clock.Now.LocalDateTime));
        Task.Run(() =>
        {
            var history = new HistoryReader(DataPaths.History).LocalLevelDays() ?? [];
            return MascotLevelLedger.Update(DataPaths.Level, MascotLevelLedger.Merge(known, history), today);
        }).ContinueWith(task => dispatcher.BeginInvoke(() =>
        {
            // 回到 UI 執行緒用 AppHost 自己的 dispatcher，不靠呼叫端的 SynchronizationContext（Fable F-06）
            levelLoading = false;
            if (!task.IsCompletedSuccessfully)
            {
                AppLog.Write($"level load failed: {task.Exception?.InnerException?.GetType().Name}");
                return;
            }
            levelDays = task.Result.Days;
            // level.json 讀不到或寫不進去：只有歷史，可能比真正的等級低；已經有值時沿用（Fable F-08）
            if (!task.Result.Saved && level is not null) return;
            var hadCard = level is not null;
            level = MascotLevel.From(levelDays, today);
            mascot.LevelChanged(level?.Level);
            if (panel is null) return;
            panel.SetModel(Model);
            // 等級卡片晚一點才加進來，面板變高：重新放，不讓它往下長出螢幕或蓋住工作列（Fable F-05）
            if (!hadCard && level is not null) PlacePanel(panel, panelFromTray);
        }));
    }

    /// <summary>外觀改變（設定或系統的深淺色）：圓環、系統匣、面板重畫；面板的材質在下次打開時套用</summary>
    private void ApplyLook()
    {
        Refresh();
        settingsWindow?.RefreshLook();
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
            ring.AgentClicked += JumpTo;
            ring.DragEnded += OnDragEnded;
            ring.MouseRightButtonUp += (_, e) =>
            {
                e.Handled = true;
                ShowMenu(fromTray: false);
            };
            ring.SetContent(Content, Details, AppPalette);
            ring.SetOptions(settings.RingTicks, settings.DockToEdge);
            _ = ring.Handle;
            PlaceRing();
        }
        else if (!settings.ShowsRing && ring is not null)
        {
            ring.Close();
            ring = null;
        }
        fullscreen.Enabled = ring is not null && settings.HideInFullscreen;
        if (ring is not null)
        {
            // 圖示樣式：圓環（C2）或角色（預設）、角色＋%
            mascotFace.ShowsPercent = settings.RingStyle == RingStyle.MascotPercent;
            ring.SetFace(settings.RingStyle == RingStyle.Ring ? GlassRingFace.Shared : mascotFace);
            ring.Opacity = settings.Opacity;
            ring.SetOptions(settings.RingTicks, settings.DockToEdge);
            if (Math.Abs(ring.RingDip - AppSettings.RingDip(settings.RingSize)) > 0.1)
            {
                ring.SetSize(AppSettings.RingDip(settings.RingSize));
                PlaceRing();
            }
        }
        if (settings.ShowsTray) tray.Show(Content, TrayPalette);
        else tray.Hide();
        ApplyVisibility();
    }

    private void ApplyVisibility()
    {
        ApplyRingVisibility();
        // 角色只在看得到時動（全螢幕隱藏、只顯示系統匣、樣式是圓環時全部停止）
        mascot.SetShown(ring is { IsVisible: true } && settings.RingStyle != RingStyle.Ring);
    }

    private void ApplyRingVisibility()
    {
        if (ring is null) return;
        var hide = settings.HideInFullscreen && fullscreen.IsFullscreen;
        if (hide)
        {
            ring.CollapseNow();
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
        // 打開面板＝看過了：完成未看與出錯的徽章拿掉
        agents.MarkSeen();
        now = Clock.Now;
        panelFromTray = fromTray;
        LoadLevel();
        var window = new PanelWindow(Model, AppPalette);
        window.RefreshRequested += () => _ = RefreshAsync();
        window.IncidentRequested += url =>
        {
            // 瀏覽器會搶走焦點，面板失焦時自己會關；打不開時面板留著（原因記在 windows-app.log）。
            // ShellExecute 在瀏覽器冷啟動時可能卡數百毫秒，放到背景執行，面板不凍住
            _ = Task.Run(() => IncidentPage.Open(url));
        };
        window.SettingsRequested += () =>
        {
            window.SafeClose();
            OpenSettings();
        };
        window.QuitRequested += Quit;
        window.Closed += (_, _) =>
        {
            if (panel != window) return;
            panel = null;
            if (ring is not null) ring.Suppressed = false;
        };
        panel = window;
        // 面板開著時圓環不展開（展開的膠囊會蓋到面板）
        if (ring is not null) ring.Suppressed = true;
        // 先建立視窗量出大小，再放到圓環旁邊或系統匣的角落
        window.Left = -10000;
        window.Top = -10000;
        window.ShowActivated = true;
        window.Show();
        window.UpdateLayout();
        var hwnd = PlacePanel(window, fromTray);
        window.Activate();
        NativeMethods.SetForegroundWindow(hwnd);
        window.PlayAppear();
    }

    /// <summary>量出面板的大小，放到圓環旁邊或系統匣的角落；回傳視窗代碼</summary>
    private IntPtr PlacePanel(PanelWindow window, bool fromTray)
    {
        window.UpdateLayout();
        var hwnd = new WindowInteropHelper(window).Handle;
        NativeMethods.GetCursorPos(out var cursor);
        var monitor = NativeMethods.Monitor(fromTray || ring is null
            ? NativeMethods.MonitorFromPoint(cursor, NativeMethods.MONITOR_DEFAULTTONEAREST)
            : NativeMethods.MonitorFromWindow(ring.Handle, NativeMethods.MONITOR_DEFAULTTONEAREST));
        if (monitor is not null)
        {
            window.FitTo(monitor);
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
        return hwnd;
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
        if (!fromTray && settings.RingStyle != RingStyle.Ring) AddMascotItems(menu);
        // 鍵盤與朗讀程式也能跳回工作階段（膠囊那一列是畫出來的、圓環不接收焦點；Codex C-03）：跳膠囊那一列彙總選出的這台工作階段
        if (RingAgent.From(agents.Sessions, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), agents.Remote) is { Session: not null } local)
        {
            Add(local.Ai == AgentKind.Claude ? "切到 Claude 的工作階段" : "切到 Codex 的工作階段", () => JumpTo(local));
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
        // 選單要能在點其他地方時收起、用鍵盤操作：先讓隱藏的系統匣視窗成為前景（圓環不搶焦點，
        // 它本身不能成為前景；剛按了右鍵，這個程序有成為前景的資格）
        NativeMethods.SetForegroundWindow(tray.Handle);
        if (!fromTray) menu.PlacementTarget = ring;
        // 選單開著時滑鼠移到選單上不算離開角色
        mascot.MenuOpened();
        menu.Closed += (_, _) => mascot.MenuClosed();
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    /// <summary>角色的動作與表情、保持展開、靜音與勿擾（同 Mac 瀏海的右鍵選單）</summary>
    private void AddMascotItems(ContextMenu menu)
    {
        var animates = mascot.Motion.AnimatesBody();
        MenuItem Item(string header, Action action, bool enabled = true, bool check = false)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled, IsCheckable = check };
            item.Click += (_, _) => action();
            return item;
        }
        var actions = new MenuItem { Header = "動作" };
        foreach (var (request, title) in MascotMenu.Actions) actions.Items.Add(Item(title, () => mascot.Play(request), animates));
        var faces = new MenuItem { Header = "表情" };
        foreach (var mood in MascotMenu.Faces) faces.Items.Add(Item(mood.Title(), () => mascot.PlayFace(mood), animates));
        menu.Items.Add(actions);
        menu.Items.Add(faces);
        if (!animates)
        {
            menu.Items.Add(new MenuItem
            {
                Header = mascot.Motion == MascotMotionLevel.Simple ? "角色動畫是「簡單」：不播動作與表情" : "角色動畫已關閉：不播動作與表情",
                IsEnabled = false,
            });
        }
        menu.Items.Add(new Separator());
        var pin = Item("保持展開", () =>
        {
            mascot.SetPinned(!mascot.Pinned);
            if (mascot.Pinned) ring?.OpenPinned();
        }, check: true);
        pin.IsChecked = mascot.Pinned;
        pin.ToolTip = "滑鼠離開也不收合；再點一次收起";
        menu.Items.Add(pin);
        if (settings.MascotQuietUntil is { } until && until > DateTimeOffset.Now)
        {
            menu.Items.Add(Item($"取消靜音（靜音到 {until.ToLocalTime():HH:mm}）", () => mascot.SetQuiet(null)));
        }
        else
        {
            menu.Items.Add(Item("靜音 1 小時", () => mascot.SetQuiet(DateTimeOffset.Now.AddHours(1))));
            menu.Items.Add(Item("勿擾到明天早上 8 點", () =>
                mascot.SetQuiet(new DateTimeOffset(MascotMoods.TomorrowMorning(DateTime.Now)))));
        }
        menu.Items.Add(new Separator());
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
        settingsWindow = new SettingsWindow(settings, store.Snapshot, Clock.Now, OnSettingsChanged, hooks);
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show();
        settingsWindow.Activate();
    }

    private void OnSettingsChanged()
    {
        SettingsFile.Save(settings);
        if (settings.LaunchAtLogin != Autostart.IsEnabled) Autostart.Set(settings.LaunchAtLogin);
        agents.SettingsChanged();
        ApplyDisplayMode();
        ApplyLook();
        mascot.SettingsChanged();
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
        SystemParameters.StaticPropertyChanged -= OnSystemParameter;
        mascot.Dispose();
        // 先關圓環再停全螢幕偵測：停止時「不是全螢幕」的通知不會把隱藏中的圓環再顯示一下
        fullscreen.Changed -= ApplyVisibility;
        panel?.SafeClose();
        settingsWindow?.Close();
        ring?.Close();
        ring = null;
        fullscreen.Dispose();
        agents.Dispose();
        store.Dispose();
        tray.Dispose();
    }
}
