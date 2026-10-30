using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 桌面上的懸浮圓環（ADR-0015 第 6 節與「懸浮圓環設計」）：層疊視窗（逐像素透明）、最上層、不搶焦點（WS_EX_NOACTIVATE）、
/// 不進 Alt+Tab（WS_EX_TOOLWINDOW）。不用 DragMove()（系統的移動迴圈會啟用視窗）：按下時捕捉滑鼠，移動超過系統的拖動距離才算拖動；
/// 放開時沒拖動就是點一下。
/// 滑鼠移上去時同一個視窗往畫面內側展開；滑鼠離開 0.4 秒後收起。視窗平常就是展開後的大小（透明的地方滑鼠穿過去），
/// 展開、收合、滑出都只改畫的內容、不改視窗大小：層疊視窗改大小的那一刻沒有新內容可畫，會露出黑底與上一格的殘影、
/// 角色也會跳過前幾格（icons 第 8 部分）。拖動時整塊一起移、也不改大小；放開後依新位置重算（展開方向變了才改一次大小）。
/// 貼在左右邊緣時（設定可關）收成半圓的小標籤，滑鼠移上去先滑出成完整圓環再展開。
/// 圓環面怎麼畫由 <see cref="IRingFace"/> 決定；這裡只管位置、展開、貼邊與動畫。
/// 閒置與收起後沒有計時器與動畫：收起的延遲是只跑一次的計時器，動畫結束時寫入最終值（不留 AnimationClock）。
/// </summary>
internal sealed class RingWindow : Window
{
    public static readonly DependencyProperty RevealProperty = DependencyProperty.Register(
        nameof(Reveal), typeof(double), typeof(RingWindow), new PropertyMetadata(1.0, (d, _) => ((RingWindow)d).RevealChanged()));
    public static readonly DependencyProperty ExpandProperty = DependencyProperty.Register(
        nameof(Expand), typeof(double), typeof(RingWindow), new PropertyMetadata(0.0, (d, _) => ((RingWindow)d).Redraw()));

    /// <summary>展開與收合的時間（秒，0.18～0.25）；角色的大小跟著它自己的彈簧（約 0.5 秒），視窗留到它收完</summary>
    private double ExpandSeconds => Mascot is not null ? 0.5 : 0.22;
    private const double RevealSeconds = 0.2;
    /// <summary>滑鼠離開後多久才收起（避免一碰就閃）</summary>
    private static readonly TimeSpan CollapseDelay = TimeSpan.FromSeconds(0.4);

    private readonly Surface surface;
    private readonly Overlay overlay;
    private readonly DispatcherTimer collapseTimer;
    private IRingFace face = GlassRingFace.Shared;
    private IntPtr handle;
    private bool pressed;
    private bool dragging;
    /// <summary>按在展開的角色上（按住捏扁、放開是點擊；不拖動、不打開面板）</summary>
    private bool pressedMascot;
    private NativeMethods.POINT pressCursor;
    private PixelRect pressRect;
    /// <summary>拖動開始時的整塊視窗：拖動中整塊一起移、不改大小（改大小那一格層疊視窗會是黑的或留著舊圖）</summary>
    private PixelRect dragStage;

    private double ringDip;
    private PixelRect ring;
    private MonitorInfo? monitor;
    /// <summary>收成標籤的那一邊（貼邊收合關閉時一律 None）</summary>
    private RingDock dock;
    /// <summary>圓環實際貼著的左右邊緣（決定往下展開與外框的方向，與貼邊收合的設定無關）</summary>
    private RingDock edge;
    /// <summary>展開後被推回工作區時，內容跟著移動的距離（DIP）</summary>
    private Vector shift;
    private RingExpandDirection direction;
    private PixelRect stage;
    private bool hoverOpen;
    private bool ignoreUntilLeave;
    private bool suppressed;
    private int transition;

    private RingContent content = RingContent.Empty;
    private RingDetails details = RingDetails.Empty;
    private Palette palette = new(false);
    private bool ticks;
    private bool dockToEdge = true;

    /// <summary>點一下（沒有拖動）</summary>
    public event Action? Clicked;
    /// <summary>點了展開後 AI 那一列（ADR-0017 第 10 節）：跳回那個工作階段，不開面板</summary>
    public event Action<RingAgent>? AgentClicked;

    /// <summary>滑鼠在可以點的 AI 那一列上（這台的工作階段）</summary>
    private bool OverAgentRow(Point point) =>
        content.Agent is not null && FloatingRingRenderer.AgentRow(Scene()) is { } row && row.Contains(point);
    /// <summary>拖動結束：參數是放開時圓環的位置（實體像素）</summary>
    public event Action<PixelRect>? DragEnded;

    public RingWindow(double sizeDip, double opacity)
    {
        Title = "AI Usage Monitor Ring";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ringDip = sizeDip;
        Width = Height = sizeDip;
        Opacity = opacity;
        surface = new Surface(this);
        overlay = new Overlay(this);
        var layers = new System.Windows.Controls.Grid();
        layers.Children.Add(surface);
        layers.Children.Add(overlay);
        Content = layers;
        Focusable = false;
        collapseTimer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = CollapseDelay };
        collapseTimer.Tick += (_, _) =>
        {
            collapseTimer.Stop();
            Collapse();
        };
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            NativeMethods.AddExStyle(handle, NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW);
            HwndSource.FromHwnd(handle)?.AddHook(WndProc);
        };
    }

    /// <summary>0＝貼邊的半圓標籤、1＝圓環在原位</summary>
    /// <summary>收成貼邊的標籤（完全收進去）</summary>
    private bool Docked => dock != RingDock.None && Reveal <= 0;

    private void RevealChanged()
    {
        Redraw();
        Mascot?.Controller.SetDocked(Docked);
    }

    public double Reveal
    {
        get => (double)GetValue(RevealProperty);
        set => SetValue(RevealProperty, value);
    }

    /// <summary>0＝圓環、1＝完整展開</summary>
    public double Expand
    {
        get => (double)GetValue(ExpandProperty);
        set => SetValue(ExpandProperty, value);
    }

    public IntPtr Handle => handle != IntPtr.Zero ? handle : (handle = new WindowInteropHelper(this).EnsureHandle());

    /// <summary>圓環的邊長（DIP，設定的大小）</summary>
    public double RingDip => ringDip;

    /// <summary>圓環的位置（實體像素；展開或收成標籤時視窗的大小不同，這個不變）</summary>
    public PixelRect Rect => ring;

    /// <summary>面板開著時不展開（膠囊會蓋到面板）</summary>
    public bool Suppressed
    {
        get => suppressed;
        set
        {
            suppressed = value;
            if (value) CollapseNow();
        }
    }

    public void SetContent(RingContent next, RingDetails nextDetails, Palette nextPalette)
    {
        // 收起時倒數文字的變化看不到：只有圓環的內容或外觀改變才重畫
        var showingDetails = hoverOpen || Expand > 0;
        var changed = content != next || palette.Dark != nextPalette.Dark || (showingDetails && details != nextDetails);
        content = next;
        details = nextDetails;
        palette = nextPalette;
        if (!changed) return;
        Redraw();
        System.Windows.Automation.AutomationProperties.SetName(this, next.AccessibilityText);
    }

    /// <summary>刻度、貼邊收合（設定改變時）</summary>
    public void SetOptions(bool showTicks, bool dockEnabled)
    {
        var dockChanged = dockToEdge != dockEnabled;
        ticks = showTicks;
        dockToEdge = dockEnabled;
        if (dockChanged && monitor is not null) MoveTo(ring);
        else Redraw();
    }

    /// <summary>換圓環面：圓環或角色（ADR-0015 第 6 節）</summary>
    public void SetFace(IRingFace next)
    {
        if (ReferenceEquals(face, next)) return;
        if (Mascot is { } old)
        {
            old.Controller.Changed -= Redraw;
            old.Controller.FrameTick -= RedrawHero;
            old.Overlay = null;
            old.Controller.CloseRequested -= CollapseNow;
            old.Controller.HeroOnScreen = null;
            old.Controller.ContainsPointer = null;
            old.Controller.PointerPolled -= HoverProbe;
            old.Controller.SetDocked(false);
        }
        face = next;
        if (Mascot is { } mascot)
        {
            mascot.Controller.Changed += Redraw;
            mascot.Controller.FrameTick += RedrawHero;
            mascot.Controller.CloseRequested += CollapseNow;
            // 貼邊的標籤是靜態的一格：不看滑鼠（ADR-0015 第 7 節「角色」）
            // 角色實際畫的位置（展開中往膠囊左端移、推回工作區的距離都照畫的那一格，Codex C-02）；還沒畫過時用圓環中心
            mascot.Controller.HeroOnScreen = () => IsVisible && monitor is not null && !Docked
                ? mascot.HeroCenter is { } c
                    ? (stage.Left + c.X * monitor.Scale, stage.Top + c.Y * monitor.Scale, monitor.Scale)
                    : (ring.Left + ring.Width / 2.0, ring.Top + ring.Height / 2.0, monitor.Scale)
                : null;
            mascot.Controller.ContainsPointer = () => IsMouseOver;
            mascot.Controller.PointerPolled += HoverProbe;
            mascot.Controller.SetDocked(Docked);
        }
        CollapseNow();
        Redraw();
    }

    private MascotFace? Mascot => face as MascotFace;

    /// <summary>右鍵選單開著或保持展開時不收（角色）</summary>
    private bool KeepsOpen => Mascot?.Controller.KeepsOpen == true;

    /// <summary>保持展開（角色的右鍵選單）：展開並留著</summary>
    public void OpenPinned()
    {
        ignoreUntilLeave = false;
        Open();
    }

    public void SetSize(double sizeDip)
    {
        ringDip = sizeDip;
        Width = Height = sizeDip;
    }

    /// <summary>移到指定位置（實體像素），收起展開；貼在左右邊緣時收成標籤</summary>
    public void MoveTo(PixelRect target)
    {
        ring = target;
        monitor = NativeMethods.Monitor(NativeMethods.MonitorFromPoint(
            new NativeMethods.POINT { X = target.Left + target.Width / 2, Y = target.Top + target.Height / 2 }, NativeMethods.MONITOR_DEFAULTTONEAREST));
        edge = monitor is not null ? RingFloatLayout.DockOf(target, monitor) : RingDock.None;
        dock = dockToEdge ? edge : RingDock.None;
        Rest();
    }

    public void BringToTop()
    {
        if (handle != IntPtr.Zero && IsVisible) NativeMethods.BringToTopmost(handle);
    }

    /// <summary>立刻收起（點一下、拖動、面板打開、全螢幕隱藏）</summary>
    public void CollapseNow()
    {
        collapseTimer.Stop();
        if (!hoverOpen && Expand <= 0 && Reveal == (dock == RingDock.None ? 1 : 0)) return;
        Rest();
    }

    // ---------- 狀態 ----------

    /// <summary>靜止：圓環在原位，或貼邊時的標籤；停掉所有動畫。視窗放成展開後的大小（拖動中也是）</summary>
    private void Rest()
    {
        transition++;
        if (hoverOpen) Mascot?.Controller.CloseNow();
        SetOpen(false);
        collapseTimer.Stop();
        StopAnimation(ExpandProperty, 0);
        StopAnimation(RevealProperty, dock == RingDock.None ? 1 : 0);
        var resting = dock == RingDock.None || monitor is null ? ring : RingFloatLayout.Tab(ring, dock, monitor);
        var target = Stage(resting);
        if (target != stage) Place(target);
        else
        {
            PublishRing();
            Redraw();
        }
    }

    /// <summary>展開會用到的整塊（實體像素）：展開的方向與推回工作區的距離也在這裡決定，展開時不必再改視窗大小</summary>
    private PixelRect Stage(PixelRect resting)
    {
        if (monitor is null) return resting;
        direction = RingFloatLayout.Direction(ring, monitor, ringDip, capsule: Mascot is not null);
        var (dx, dy) = RingFloatLayout.ExpandedShift(ring, direction, monitor, ringDip);
        shift = new Vector(dx / monitor.Scale, dy / monitor.Scale);
        return RingFloatLayout.Union(RingFloatLayout.Union(RingFloatLayout.Expanded(ring, direction, monitor, ringDip), ring), resting);
    }

    /// <summary>圓環的位置寫進視窗屬性（每次 ring 可能改變都寫，整塊沒變時也是）</summary>
    private void PublishRing()
    {
        int[] edges = [ring.Left, ring.Top, ring.Right, ring.Bottom];
        for (var i = 0; i < RingProps.Length; i++) NativeMethods.SetProp(Handle, RingProps[i], edges[i]);
    }

    private void SetOpen(bool open)
    {
        hoverOpen = open;
        if (handle != IntPtr.Zero) NativeMethods.SetProp(handle, ExpandedProp, open ? 1 : 0);
    }

    /// <summary>量測腳本讀的視窗屬性（展開中 1）：視窗大小不再隨展開改變，腳本靠這個知道有沒有展開</summary>
    public const string ExpandedProp = "AIUsageMonitor.Expanded";
    /// <summary>圓環本身的位置（實體像素的左、上、右、下）：視窗比圓環大，腳本靠這個把游標移到圓環上</summary>
    private static readonly string[] RingProps = ["AIUsageMonitor.RingLeft", "AIUsageMonitor.RingTop", "AIUsageMonitor.RingRight", "AIUsageMonitor.RingBottom"];

    /// <summary>
    /// 低頻輪詢讀到的游標（實體像素，角色的 <see cref="MascotController.PointerPolled"/>）：補判滑鼠移上去與離開。
    /// 只靠 MouseEnter 的話，程式移動游標、或層疊視窗那一刻沒收到 WM_MOUSEMOVE 時就不會展開；展開後游標不在膠囊與圓環的範圍、
    /// 而 WPF 也沒收到離開時照常 0.4 秒後收起
    /// </summary>
    private void HoverProbe(int x, int y)
    {
        if (monitor is null || pressed || dragging || !IsVisible) return;
        if (!hoverOpen)
        {
            // 貼邊的標籤不看滑鼠、不輪詢（不會走到這裡），只靠 MouseEnter
            if (InCircle(ring, x, y, 0.8)) Open();
            // 離開整塊才算「離開一次」：圓環矩形裡透明的地方不算
            else if (!stage.Contains(x, y)) ignoreUntilLeave = false;
            return;
        }
        if (IsMouseOver || KeepsOpen || collapseTimer.IsEnabled) return;
        // 只補「離開」：膠囊兩端圓角外的透明處由 MouseLeave 開始倒數，這裡不停掉它
        if (!RingFloatLayout.Union(RingFloatLayout.Expanded(ring, direction, monitor, ringDip), ring).Contains(x, y)) collapseTimer.Start();
    }

    /// <summary>點在圓（<paramref name="rect"/> 的內切圓，半徑乘 <paramref name="part"/>）裡</summary>
    private static bool InCircle(PixelRect rect, int x, int y, double part)
    {
        var r = rect.Width / 2.0 * part;
        var dx = x - (rect.Left + rect.Width / 2.0);
        var dy = y - (rect.Top + rect.Height / 2.0);
        return dx * dx + dy * dy <= r * r;
    }

    private void Open()
    {
        if (monitor is null || suppressed || pressed || ignoreUntilLeave || !IsVisible) return;
        collapseTimer.Stop();
        if (hoverOpen) return;
        SetOpen(true);
        Mascot?.Controller.PointerEntered();
        // 視窗平常就是這個大小（Rest）；換了螢幕、DPI 等情況不同時才改，改完先畫一次再開始動畫
        var target = Stage(dock == RingDock.None ? ring : RingFloatLayout.Tab(ring, dock, monitor));
        if (target != stage) Place(target);
        var id = ++transition;
        if (dock != RingDock.None && Reveal < 1)
        {
            Animate(RevealProperty, 1, RevealSeconds, () =>
            {
                if (id == transition) Animate(ExpandProperty, 1, ExpandSeconds, null);
            });
        }
        else
        {
            Animate(ExpandProperty, 1, ExpandSeconds, null);
        }
    }

    private void Collapse()
    {
        if (!hoverOpen || KeepsOpen) return;
        SetOpen(false);
        Mascot?.Controller.CloseNow();
        var id = ++transition;
        Animate(ExpandProperty, 0, ExpandSeconds, () =>
        {
            if (id != transition) return;
            if (dock == RingDock.None)
            {
                Rest();
                return;
            }
            Animate(RevealProperty, 0, RevealSeconds, () =>
            {
                if (id == transition) Rest();
            });
        });
    }

    /// <summary>從目前（可能正在動畫中）的值走到 <paramref name="to"/>；系統關閉「顯示動畫」時直接切換</summary>
    private void Animate(DependencyProperty property, double to, double seconds, Action? then)
    {
        var from = (double)GetValue(property);
        var distance = Math.Abs(to - from);
        if (!SystemLook.AnimationsEnabled || distance < 0.001)
        {
            StopAnimation(property, to);
            then?.Invoke();
            return;
        }
        // 基準值先設成終點：動畫（FillBehavior.Stop）結束後就停在終點，不留 AnimationClock
        BeginAnimation(property, null);
        SetValue(property, to);
        var animation = new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds * distance)) { FillBehavior = FillBehavior.Stop };
        if (then is not null) animation.Completed += (_, _) => then();
        BeginAnimation(property, animation);
    }

    private void StopAnimation(DependencyProperty property, double value)
    {
        BeginAnimation(property, null);
        SetValue(property, value);
    }

    /// <summary>視窗放到 <paramref name="rect"/>（實體像素）；與圓環同一個螢幕，DIP 大小依它的 DPI</summary>
    private void Place(PixelRect rect)
    {
        stage = rect;
        PublishRing();
        // 先移過去：跨到 DPI 不同的螢幕時 WPF 依 WM_DPICHANGED 改大小，之後再以新的 DPI 設 DIP 大小、對齊一次
        NativeMethods.PlaceWindow(Handle, rect);
        var scale = monitor?.Scale ?? VisualTreeHelper.GetDpi(this).DpiScaleX;
        Width = rect.Width / scale;
        Height = rect.Height / scale;
        if (NativeMethods.WindowRect(Handle) != rect) NativeMethods.PlaceWindow(Handle, rect);
        Redraw();
    }

    private FloatingScene Scene()
    {
        var scale = monitor?.Scale ?? 1;
        Point Local(double x, double y) => new((x - stage.Left) / scale, (y - stage.Top) / scale);
        var center = Local(ring.Left + ring.Width / 2.0, ring.Top + ring.Height / 2.0);
        var tabCenter = center;
        System.Windows.Rect? visible = null;
        if (dock != RingDock.None && monitor is not null)
        {
            var tab = RingFloatLayout.Tab(ring, dock, monitor);
            tabCenter = Local(dock == RingDock.Left ? tab.Left : tab.Right, ring.Top + ring.Height / 2.0);
            var corner = Local(tab.Left, tab.Top);
            visible = new System.Windows.Rect(corner.X, corner.Y, tab.Width / scale, tab.Height / scale);
        }
        return new FloatingScene(content, details, palette, face, ticks, ringDip, direction, edge, center, tabCenter, visible,
                                 Reveal, Expand, VisualTreeHelper.GetDpi(this).PixelsPerDip) { Shift = shift };
    }

    /// <summary>換了 DPI（換螢幕、改縮放）：整個重畫，角色不會停在舊 DPI 的點陣圖（Fable F-06）</summary>
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        Redraw();
    }

    // ---------- 滑鼠 ----------

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        Open();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        ignoreUntilLeave = false;
        if (!pressed && hoverOpen && !KeepsOpen) collapseTimer.Start();
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        // 展開時按在角色上：交給角色（按住捏扁、放開是點擊）
        if (hoverOpen && Mascot is { } mascot && mascot.ToCanvas(e.GetPosition(surface)) is { } point
            && mascot.Controller.PointerDown(point.X, point.Y))
        {
            pressedMascot = CaptureMouse();
            e.Handled = true;
            return;
        }
        NativeMethods.GetCursorPos(out pressCursor);
        pressRect = ring;
        pressed = CaptureMouse();
        dragging = false;
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        // 手勢只在這個視窗裡偵測（繞圈、甩動、停留）
        if (hoverOpen && Mascot is { } mascot && mascot.ToCanvas(e.GetPosition(surface)) is { } point)
        {
            mascot.Controller.PointerMoved(point.X, point.Y);
        }
        // 這台的工作階段那一列：游標變手指（其他電腦的不能跳，不顯示可以點的樣子）
        var hand = !pressed && content.Agent?.Session is not null && OverAgentRow(e.GetPosition(surface));
        if ((Cursor == Cursors.Hand) != hand) Cursor = hand ? Cursors.Hand : null;
        if (!pressed) return;
        NativeMethods.GetCursorPos(out var cursor);
        var dx = cursor.X - pressCursor.X;
        var dy = cursor.Y - pressCursor.Y;
        if (!dragging)
        {
            var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            dragging = Math.Abs(dx) > SystemParameters.MinimumHorizontalDragDistance * scale
                       || Math.Abs(dy) > SystemParameters.MinimumVerticalDragDistance * scale;
            if (!dragging) return;
            // 拖動的是圓環本身：收起展開、從標籤拉出來
            dock = RingDock.None;
            edge = RingDock.None;
            Rest();
            dragStage = stage.Offset(pressRect.Left - ring.Left, pressRect.Top - ring.Top);
        }
        NativeMethods.MoveWindow(Handle, dragStage.Left + dx, dragStage.Top + dy);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (pressedMascot)
        {
            pressedMascot = false;
            if (IsMouseCaptured) ReleaseMouseCapture();
            if (Mascot is { } mascot && mascot.ToCanvas(e.GetPosition(surface)) is { } point) mascot.Controller.PointerUp(point.X, point.Y);
            e.Handled = true;
            return;
        }
        if (!pressed) return;
        var wasDragging = dragging;
        Finish();
        e.Handled = true;
        // 放開後滑鼠還在圓環上：離開一次之前不再展開
        ignoreUntilLeave = true;
        if (wasDragging)
        {
            DragEnded?.Invoke(Dragged());
        }
        else if (content.Agent is { } agent && OverAgentRow(e.GetPosition(surface)))
        {
            AgentClicked?.Invoke(agent);
        }
        else
        {
            CollapseNow();
            Clicked?.Invoke();
        }
    }

    /// <summary>拖到的圓環位置（實體像素）：視窗比圓環大，依圓環在整塊裡的位置換算</summary>
    private PixelRect Dragged()
    {
        var window = NativeMethods.WindowRect(Handle);
        return ring.Offset(window.Left - stage.Left, window.Top - stage.Top);
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (pressedMascot)
        {
            pressedMascot = false;
            Mascot?.Controller.PointerUp(double.NaN, double.NaN);
            return;
        }
        if (!pressed) return;
        // 拖動中失去捕捉（例如按了 Win 鍵）：當作放開
        var wasDragging = dragging;
        Finish();
        if (wasDragging) DragEnded?.Invoke(Dragged());
    }

    protected override void OnClosed(EventArgs e)
    {
        SetFace(GlassRingFace.Shared);
        collapseTimer.Stop();
        BeginAnimation(ExpandProperty, null);
        BeginAnimation(RevealProperty, null);
        base.OnClosed(e);
    }

    private void Finish()
    {
        pressed = false;
        dragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        // 點圓環不啟用視窗（WS_EX_NOACTIVATE 之外再保險一次）
        if (msg == NativeMethods.WM_MOUSEACTIVATE)
        {
            handled = true;
            return new IntPtr(NativeMethods.MA_NOACTIVATE);
        }
        return IntPtr.Zero;
    }

    /// <summary>角色的狀態變了：整個重畫（圓環畫的時候決定角色要不要放到上面那一層）</summary>
    private void Redraw()
    {
        surface.InvalidateVisual();
        overlay.InvalidateVisual();
    }

    /// <summary>看滑鼠的一格：和上一次畫的看不出差別就不畫；展開的膠囊已經畫過（角色由上面那一層畫）時只重畫那一層，否則整個重畫</summary>
    private void RedrawHero()
    {
        if (Mascot?.ShowsSameFrame(VisualTreeHelper.GetDpi(this).PixelsPerDip) == true) return;
        if (Mascot?.Overlay is not null) overlay.InvalidateVisual();
        else Redraw();
    }

    /// <summary>角色那一層（展開時看滑鼠，<see cref="MascotFace.Overlay"/>）：不接收滑鼠</summary>
    private sealed class Overlay : FrameworkElement
    {
        private readonly RingWindow owner;

        public Overlay(RingWindow owner)
        {
            this.owner = owner;
            IsHitTestVisible = false;
        }

        protected override void OnRender(DrawingContext dc) => owner.Mascot?.Overlay?.Invoke(dc);
    }

    private sealed class Surface(RingWindow owner) : FrameworkElement
    {
        protected override void OnRender(DrawingContext dc)
        {
            if (owner.stage.Width == 0) return;
            FloatingRingRenderer.Draw(dc, owner.Scene());
        }

        /// <summary>
        /// 滑鼠每移動一次 WPF 都做一次命中測試：預設會拿整張圖（漸層、文字、角色）的幾何去比，看滑鼠時就在吃 CPU（icons 第 4 部分第三版）。
        /// 透明的地方 Windows 本來就讓滑鼠穿過（分層視窗照 alpha），這裡只要看在不在範圍內。前提是 <see cref="Window.AllowsTransparency"/>：
        /// 改成不透明視窗的話要改回照圖的幾何判斷，不然整個矩形都會接到滑鼠（Fable F-10）
        /// </summary>
        protected override HitTestResult? HitTestCore(PointHitTestParameters hit) =>
            new Rect(RenderSize).Contains(hit.HitPoint) ? new PointHitTestResult(this, hit.HitPoint) : null;
    }
}
