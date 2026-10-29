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
/// 滑鼠移上去時同一個視窗往畫面內側展開（展開或滑出的過程中視窗大小不變，只改畫的內容）；滑鼠離開 0.4 秒後收起。
/// 貼在左右邊緣時（設定可關）收成半圓的小標籤，滑鼠移上去先滑出成完整圓環再展開。
/// 圓環面怎麼畫由 <see cref="IRingFace"/> 決定；這裡只管位置、展開、貼邊與動畫。
/// 閒置與收起後沒有計時器與動畫：收起的延遲是只跑一次的計時器，動畫結束時寫入最終值（不留 AnimationClock）。
/// </summary>
internal sealed class RingWindow : Window
{
    public static readonly DependencyProperty RevealProperty = DependencyProperty.Register(
        nameof(Reveal), typeof(double), typeof(RingWindow), new PropertyMetadata(1.0, (d, _) => ((RingWindow)d).RevealChanged()));
    public static readonly DependencyProperty ExpandProperty = DependencyProperty.Register(
        nameof(Expand), typeof(double), typeof(RingWindow), new PropertyMetadata(0.0, (d, _) => ((RingWindow)d).surface.InvalidateVisual()));

    /// <summary>展開與收合的時間（秒，0.18～0.25）；角色的大小跟著它自己的彈簧（約 0.5 秒），視窗留到它收完</summary>
    private double ExpandSeconds => Mascot is not null ? 0.5 : 0.22;
    private const double RevealSeconds = 0.2;
    /// <summary>滑鼠離開後多久才收起（避免一碰就閃）</summary>
    private static readonly TimeSpan CollapseDelay = TimeSpan.FromSeconds(0.4);

    private readonly Surface surface;
    private readonly DispatcherTimer collapseTimer;
    private IRingFace face = GlassRingFace.Shared;
    private IntPtr handle;
    private bool pressed;
    private bool dragging;
    /// <summary>按在展開的角色上（按住捏扁、放開是點擊；不拖動、不打開面板）</summary>
    private bool pressedMascot;
    private NativeMethods.POINT pressCursor;
    private PixelRect pressRect;

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
        Content = surface;
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
        surface.InvalidateVisual();
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
        surface.InvalidateVisual();
        System.Windows.Automation.AutomationProperties.SetName(this, next.AccessibilityText);
    }

    /// <summary>刻度、貼邊收合（設定改變時）</summary>
    public void SetOptions(bool showTicks, bool dockEnabled)
    {
        var dockChanged = dockToEdge != dockEnabled;
        ticks = showTicks;
        dockToEdge = dockEnabled;
        if (dockChanged && monitor is not null) MoveTo(ring);
        else surface.InvalidateVisual();
    }

    /// <summary>換圓環面：圓環或角色（ADR-0015 第 6 節）</summary>
    public void SetFace(IRingFace next)
    {
        if (ReferenceEquals(face, next)) return;
        if (Mascot is { } old)
        {
            old.Controller.Changed -= surface.InvalidateVisual;
            old.Controller.CloseRequested -= CollapseNow;
            old.Controller.HeroOnScreen = null;
            old.Controller.ContainsPointer = null;
            old.Controller.SetDocked(false);
        }
        face = next;
        if (Mascot is { } mascot)
        {
            mascot.Controller.Changed += surface.InvalidateVisual;
            mascot.Controller.CloseRequested += CollapseNow;
            // 貼邊的標籤是靜態的一格：不看滑鼠（ADR-0015 第 7 節「角色」）
            mascot.Controller.HeroOnScreen = () => IsVisible && monitor is not null && !Docked
                ? (ring.Left + ring.Width / 2.0, ring.Top + ring.Height / 2.0, monitor.Scale) : null;
            mascot.Controller.ContainsPointer = () => IsMouseOver;
            mascot.Controller.SetDocked(Docked);
        }
        CollapseNow();
        surface.InvalidateVisual();
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

    /// <summary>靜止：圓環在原位，或貼邊時的標籤；停掉所有動畫</summary>
    private void Rest()
    {
        transition++;
        if (hoverOpen) Mascot?.Controller.CloseNow();
        hoverOpen = false;
        collapseTimer.Stop();
        StopAnimation(ExpandProperty, 0);
        StopAnimation(RevealProperty, dock == RingDock.None ? 1 : 0);
        Place(dock == RingDock.None || monitor is null ? ring : RingFloatLayout.Tab(ring, dock, monitor));
    }

    private void Open()
    {
        if (monitor is null || suppressed || pressed || ignoreUntilLeave || !IsVisible) return;
        collapseTimer.Stop();
        if (hoverOpen) return;
        hoverOpen = true;
        Mascot?.Controller.PointerEntered();
        direction = RingFloatLayout.Direction(ring, monitor, ringDip);
        var expanded = RingFloatLayout.Expanded(ring, direction, monitor, ringDip);
        var (dx, dy) = RingFloatLayout.ExpandedShift(ring, direction, monitor, ringDip);
        shift = new Vector(dx / monitor.Scale, dy / monitor.Scale);
        var target = RingFloatLayout.Union(expanded, ring);
        if (dock != RingDock.None) target = RingFloatLayout.Union(target, RingFloatLayout.Tab(ring, dock, monitor));
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
        hoverOpen = false;
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
        // 先移過去：跨到 DPI 不同的螢幕時 WPF 依 WM_DPICHANGED 改大小，之後再以新的 DPI 設 DIP 大小、對齊一次
        NativeMethods.PlaceWindow(Handle, rect);
        var scale = monitor?.Scale ?? VisualTreeHelper.GetDpi(this).DpiScaleX;
        Width = rect.Width / scale;
        Height = rect.Height / scale;
        if (NativeMethods.WindowRect(Handle) != rect) NativeMethods.PlaceWindow(Handle, rect);
        surface.InvalidateVisual();
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
        }
        NativeMethods.MoveWindow(Handle, pressRect.Left + dx, pressRect.Top + dy);
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
            DragEnded?.Invoke(NativeMethods.WindowRect(Handle));
        }
        else
        {
            CollapseNow();
            Clicked?.Invoke();
        }
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
        if (wasDragging) DragEnded?.Invoke(NativeMethods.WindowRect(Handle));
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

    private sealed class Surface(RingWindow owner) : FrameworkElement
    {
        protected override void OnRender(DrawingContext dc)
        {
            if (owner.stage.Width == 0) return;
            FloatingRingRenderer.Draw(dc, owner.Scene());
        }
    }
}
