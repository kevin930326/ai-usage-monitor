using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 系統匣圖示（Shell_NotifyIcon，不引入 WinForms；uID = 1、不用 GUID，ADR-0015 識別字）。
/// 隱藏的訊息視窗也收 WM_SETTINGCHANGE（深淺色、透明效果）與 WM_DISPLAYCHANGE（螢幕改變），通知 App。
/// 圖示與圓環用同一個繪圖程式；內容相同時不換圖。
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint IconId = 1;
    private const int CallbackMessage = NativeMethods.WM_APP + 1;

    private readonly HwndSource window;
    private readonly uint taskbarCreated;
    private IntPtr icon;
    private bool added;
    private RingContent? shown;
    private bool shownDark;
    private string tip = "AI Usage Monitor";

    public event Action? DoubleClicked;
    /// <summary>右鍵或鍵盤的選單鍵：參數是螢幕座標（實體像素）</summary>
    public event Action<int, int>? ContextMenuRequested;
    public event Action? SettingsChanged;
    public event Action? DisplayChanged;

    public TrayIcon()
    {
        // 一般的隱藏頂層視窗（不是 HWND_MESSAGE）：才收得到 TaskbarCreated 與 WM_SETTINGCHANGE 的廣播
        window = new HwndSource(new HwndSourceParameters("AI Usage Monitor Tray") { Width = 0, Height = 0, WindowStyle = unchecked((int)0x80000000) });
        window.AddHook(WndProc);
        taskbarCreated = NativeMethods.RegisterWindowMessage("TaskbarCreated");
    }

    public IntPtr Handle => window.Handle;
    public bool Visible { get; private set; }

    public void Show(RingContent content, Palette palette)
    {
        Visible = true;
        Update(content, palette);
    }

    public void Hide()
    {
        Visible = false;
        Remove();
    }

    public void Update(RingContent content, Palette palette)
    {
        if (!Visible) return;
        if (added && content == shown && palette.Dark == shownDark) return;
        var newIcon = Render(content, palette);
        tip = Truncate(content.Tooltip, 127);
        var data = Data(NativeMethods.NIF_ICON | NativeMethods.NIF_TIP | NativeMethods.NIF_SHOWTIP | NativeMethods.NIF_MESSAGE, newIcon);
        if (!added)
        {
            added = NativeMethods.Shell_NotifyIcon(NativeMethods.NIM_ADD, ref data);
            if (added)
            {
                data.VersionOrTimeout = NativeMethods.NOTIFYICON_VERSION_4;
                NativeMethods.Shell_NotifyIcon(NativeMethods.NIM_SETVERSION, ref data);
            }
        }
        else
        {
            NativeMethods.Shell_NotifyIcon(NativeMethods.NIM_MODIFY, ref data);
        }
        if (icon != IntPtr.Zero) NativeMethods.DestroyIcon(icon);
        icon = newIcon;
        shown = content;
        shownDark = palette.Dark;
    }

    /// <summary>
    /// 通知（ADR-0019：NIF_INFO，Windows 10 起顯示成系統通知；不需要註冊 AUMID）。只有標題與一行文字，沒有任何按鈕。
    /// 系統匣圖示沒有顯示時發不出來，回傳 false
    /// </summary>
    public bool Notify(string title, string body)
    {
        if (!added) return false;
        var data = Data(NativeMethods.NIF_INFO, icon);
        data.InfoTitle = Truncate(title, 63);
        data.Info = Truncate(body, 255);
        data.InfoFlags = NativeMethods.NIIF_INFO | NativeMethods.NIIF_RESPECT_QUIET_TIME;
        return NativeMethods.Shell_NotifyIcon(NativeMethods.NIM_MODIFY, ref data);
    }

    private NativeMethods.NOTIFYICONDATA Data(uint flags, IntPtr withIcon) => new()
    {
        Size = Marshal.SizeOf<NativeMethods.NOTIFYICONDATA>(),
        Window = window.Handle,
        Id = IconId,
        Flags = flags,
        CallbackMessage = CallbackMessage,
        Icon = withIcon,
        Tip = tip,
        Info = "",
        InfoTitle = "",
    };

    private void Remove()
    {
        if (!added) return;
        var data = Data(0, IntPtr.Zero);
        NativeMethods.Shell_NotifyIcon(NativeMethods.NIM_DELETE, ref data);
        added = false;
        shown = null;
    }

    /// <summary>以系統匣的 DPI 畫成 HICON（16 DIP；圖示的深淺色跟工作列，Windows 11 的工作列預設深色）</summary>
    private IntPtr Render(RingContent content, Palette palette)
    {
        var dpiScale = window.CompositionTarget?.TransformToDevice.M11 ?? 1;
        var pixels = (int)Math.Round(16 * dpiScale);
        var bitmap = RenderBitmap(content, palette, pixels);
        var stride = pixels * 4;
        var bgra = new byte[stride * pixels];
        bitmap.CopyPixels(bgra, stride, 0);
        return NativeMethods.CreateIcon(bgra, pixels, pixels);
    }

    public static BitmapSource RenderBitmap(RingContent content, Palette palette, int pixels)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            RingDrawing.DrawTray(dc, content, pixels, palette);
        }
        var bitmap = new RenderTargetBitmap(pixels, pixels, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            // NOTIFYICON_VERSION_4：lParam 低位是事件，wParam 是座標
            var kind = (int)(lParam.ToInt64() & 0xFFFF);
            var x = (short)(wParam.ToInt64() & 0xFFFF);
            var y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            switch (kind)
            {
                case NativeMethods.WM_LBUTTONDBLCLK:
                case NativeMethods.NIN_KEYSELECT:
                    DoubleClicked?.Invoke();
                    break;
                case NativeMethods.WM_CONTEXTMENU:
                    ContextMenuRequested?.Invoke(x, y);
                    break;
            }
            handled = true;
        }
        else if (msg == (int)taskbarCreated && taskbarCreated != 0)
        {
            // Explorer 重新啟動：重新加入圖示
            added = false;
            shown = null;
            if (Visible) SettingsChanged?.Invoke();
        }
        else if (msg == NativeMethods.WM_SETTINGCHANGE && lParam != IntPtr.Zero
                 && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            // 只處理深淺色、輔色與透明效果的改變（ImmersiveColorSet）；環境變數等其他廣播不重畫、不關面板
            SettingsChanged?.Invoke();
        }
        else if (msg == NativeMethods.WM_DISPLAYCHANGE)
        {
            DisplayChanged?.Invoke();
        }
        return IntPtr.Zero;
    }

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";

    public void Dispose()
    {
        Remove();
        if (icon != IntPtr.Zero) NativeMethods.DestroyIcon(icon);
        icon = IntPtr.Zero;
        window.RemoveHook(WndProc);
        window.Dispose();
    }
}
