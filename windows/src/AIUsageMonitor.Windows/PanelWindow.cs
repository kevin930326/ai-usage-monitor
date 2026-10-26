using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 面板視窗（ADR-0015 第 1、6 節）：Windows 11 22621 起用 DWM 的 Acrylic（暫時性視窗），其他情況與「透明效果」關閉時純色。
/// 要被啟用才收得到 Deactivated：點面板外（失去焦點）、Esc、再點一次圓環時收起。收起＝關閉視窗，下次重新建立，
/// 關閉後不留任何計時器與動畫。
/// </summary>
internal sealed class PanelWindow : Window
{
    public static readonly DependencyProperty AppearProperty = DependencyProperty.Register(
        nameof(Appear), typeof(double), typeof(PanelWindow), new PropertyMetadata(1.0, (d, e) => ((PanelWindow)d).content?.SetAppear((double)e.NewValue)));

    public static readonly DependencyProperty MarkerProperty = DependencyProperty.Register(
        nameof(Marker), typeof(double), typeof(PanelWindow), new PropertyMetadata(1.0, (d, e) => ((PanelWindow)d).content?.SetMarker((double)e.NewValue)));

    private readonly Palette palette;
    private PanelContent? content;
    private bool backdrop;
    private bool closing;

    public event Action? RefreshRequested;
    public event Action? SettingsRequested;
    public event Action? QuitRequested;

    public PanelWindow(PanelModel model, Palette palette)
    {
        this.palette = palette;
        Title = "AI Usage Monitor";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.Height;
        Width = PanelContent.PanelWidth;
        MaxHeight = SystemParameters.WorkArea.Height - 40;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            GlassFrameThickness = new Thickness(-1),
            ResizeBorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            UseAeroCaptionButtons = false,
        });
        Background = palette.Solid;
        SetModel(model);
        SourceInitialized += (_, _) => ApplyFrame();
        Deactivated += (_, _) => SafeClose();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) SafeClose();
        };
    }

    public double Appear
    {
        get => (double)GetValue(AppearProperty);
        set => SetValue(AppearProperty, value);
    }

    public double Marker
    {
        get => (double)GetValue(MarkerProperty);
        set => SetValue(MarkerProperty, value);
    }

    /// <summary>資料或時間改變（每分鐘）時換內容，不播動畫</summary>
    public void SetModel(PanelModel model)
    {
        var next = new PanelContent(model, palette);
        next.RefreshRequested += () => RefreshRequested?.Invoke();
        next.SettingsRequested += () => SettingsRequested?.Invoke();
        next.QuitRequested += () => QuitRequested?.Invoke();
        content = next;
        Content = new System.Windows.Controls.ScrollViewer
        {
            Content = next,
            VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        next.SetAppear(Appear);
        next.SetMarker(Marker);
    }

    /// <summary>打開時：主圓環描繪與進度條長出 0.6 秒、預期標記 0.45 秒後淡入 0.2 秒（ADR-0010 第一階段）。系統關閉動畫時直接顯示</summary>
    public void PlayAppear()
    {
        if (!SystemLook.AnimationsEnabled) return;
        Animate(AppearProperty, 0.6, 0);
        Animate(MarkerProperty, 0.2, 0.45);
    }

    private void Animate(DependencyProperty property, double seconds, double delay)
    {
        // 基準值保持 1，動畫結束（FillBehavior.Stop）後回到 1，不留 AnimationClock
        var animation = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(seconds))
        {
            BeginTime = TimeSpan.FromSeconds(delay),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop,
        };
        SetValue(property, 0.0);
        animation.Completed += (_, _) => SetValue(property, 1.0);
        BeginAnimation(property, animation);
    }

    private void ApplyFrame()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        NativeMethods.AddExStyle(hwnd, NativeMethods.WS_EX_TOOLWINDOW);
        NativeMethods.SetDwm(hwnd, NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE, NativeMethods.DWMWCP_ROUND);
        NativeMethods.SetDwm(hwnd, NativeMethods.DWMWA_USE_IMMERSIVE_DARK_MODE, palette.Dark ? 1 : 0);
        backdrop = SystemLook.SupportsBackdrop && SystemLook.TransparencyEnabled
                   && NativeMethods.SetDwm(hwnd, NativeMethods.DWMWA_SYSTEMBACKDROP_TYPE, NativeMethods.DWMSBT_TRANSIENTWINDOW);
        if (backdrop)
        {
            // 材質從 DWM 畫：WPF 的背景改成透明，邊框延伸到整個視窗
            Background = Brushes.Transparent;
            if (HwndSource.FromHwnd(hwnd)?.CompositionTarget is { } target) target.BackgroundColor = Colors.Transparent;
            var margins = new NativeMethods.MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            NativeMethods.DwmExtendFrameIntoClientArea(hwnd, ref margins);
        }
        else
        {
            Background = palette.Solid;
        }
    }

    /// <summary>放到指定位置（實體像素）</summary>
    public void PlaceAt(PixelRect rect)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        NativeMethods.MoveWindow(hwnd, rect.Left, rect.Top);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        closing = true;
        base.OnClosing(e);
    }

    public bool IsClosing => closing;

    /// <summary>關閉中（Closing 之後）又收到 Deactivated 時不再呼叫 Close（WPF 會丟例外）</summary>
    public void SafeClose()
    {
        if (!closing) Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        // 停掉還在播的動畫（AnimationClock 不會留在已關閉的視窗上）
        BeginAnimation(AppearProperty, null);
        BeginAnimation(MarkerProperty, null);
        content = null;
        Content = null;
        base.OnClosed(e);
    }
}
