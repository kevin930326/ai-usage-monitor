using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 桌面上的懸浮圓環（ADR-0015 第 6 節）：層疊視窗（逐像素透明）、最上層、不搶焦點（WS_EX_NOACTIVATE）、不進 Alt+Tab（WS_EX_TOOLWINDOW）。
/// 不用 DragMove()（系統的移動迴圈會啟用視窗）：按下時捕捉滑鼠，移動超過系統的拖動距離才算拖動；放開時沒拖動就是點一下。
/// </summary>
internal sealed class RingWindow : Window
{
    private readonly RingElement ring;
    private IntPtr handle;
    private bool pressed;
    private bool dragging;
    private NativeMethods.POINT pressCursor;
    private PixelRect pressRect;

    /// <summary>點一下（沒有拖動）</summary>
    public event Action? Clicked;
    /// <summary>拖動結束：參數是放開時的位置（實體像素）</summary>
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
        Width = Height = sizeDip;
        Opacity = opacity;
        ring = new RingElement();
        Content = ring;
        Focusable = false;
        ToolTipService.SetInitialShowDelay(this, 400);
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            NativeMethods.AddExStyle(handle, NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW);
            HwndSource.FromHwnd(handle)?.AddHook(WndProc);
        };
    }

    public IntPtr Handle => handle != IntPtr.Zero ? handle : (handle = new WindowInteropHelper(this).EnsureHandle());

    public void SetContent(RingContent content, Palette palette)
    {
        if (ring.Content == content && ring.Palette?.Dark == palette.Dark) return;
        ring.Content = content;
        ring.Palette = palette;
        ring.InvalidateVisual();
        ToolTip = content.Tooltip;
        System.Windows.Automation.AutomationProperties.SetName(this, content.AccessibilityText);
    }

    public void SetSize(double sizeDip)
    {
        Width = Height = sizeDip;
    }

    public PixelRect Rect => NativeMethods.WindowRect(Handle);

    /// <summary>移到指定位置（實體像素）。跨到 DPI 不同的螢幕時 WPF 會依 WM_DPICHANGED 改大小，再對齊一次</summary>
    public void MoveTo(PixelRect target)
    {
        NativeMethods.MoveWindow(Handle, target.Left, target.Top);
        var actual = Rect;
        if (actual.Left != target.Left || actual.Top != target.Top) NativeMethods.MoveWindow(Handle, target.Left, target.Top);
    }

    public void BringToTop()
    {
        if (handle != IntPtr.Zero && IsVisible) NativeMethods.BringToTopmost(handle);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        NativeMethods.GetCursorPos(out pressCursor);
        pressRect = Rect;
        pressed = CaptureMouse();
        dragging = false;
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
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
            ToolTip = null;
        }
        NativeMethods.MoveWindow(Handle, pressRect.Left + dx, pressRect.Top + dy);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (!pressed) return;
        var wasDragging = dragging;
        Finish();
        if (wasDragging) DragEnded?.Invoke(Rect);
        else Clicked?.Invoke();
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (!pressed) return;
        // 拖動中失去捕捉（例如按了 Win 鍵）：當作放開
        var wasDragging = dragging;
        Finish();
        if (wasDragging) DragEnded?.Invoke(Rect);
    }

    private void Finish()
    {
        pressed = false;
        dragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        ToolTip = ring.Content?.Tooltip;
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

    private sealed class RingElement : FrameworkElement
    {
        public RingContent? Content;
        public Palette? Palette;

        protected override void OnRender(DrawingContext dc)
        {
            if (Content is null || Palette is null) return;
            RingDrawing.DrawFloating(dc, Content, Math.Min(ActualWidth, ActualHeight), Palette);
        }
    }
}
