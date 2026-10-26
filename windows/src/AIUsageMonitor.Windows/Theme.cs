using System;
using System.Windows;
using System.Windows.Media;
using AIUsageMonitor.Core;
using Microsoft.Win32;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 淺色與深色的顏色（UsageKit 的 UsagePalette，設計 skill 第 1 節）。
/// 文字一律主要／次要文字色，顏色只用在圓環、進度條、服務圖示與提示文字。
/// </summary>
internal sealed class Palette
{
    public bool Dark { get; }

    public Palette(bool dark)
    {
        Dark = dark;
        Primary = Freeze(new SolidColorBrush(dark ? Color.FromRgb(0xFF, 0xFF, 0xFF) : Color.FromArgb(0xE6, 0, 0, 0)));
        Secondary = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x99, 0, 0, 0)));
        Tertiary = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0x5C, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x5C, 0, 0, 0)));
        CardFill = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0x0C, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x0C, 0, 0, 0)));
        CardBorder = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0x12, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x12, 0, 0, 0)));
        ControlFill = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x10, 0, 0, 0)));
        ControlPressed = Freeze(new SolidColorBrush(dark ? Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x24, 0, 0, 0)));
        Solid = Freeze(new SolidColorBrush(dark ? Color.FromRgb(0x20, 0x20, 0x20) : Color.FromRgb(0xF3, 0xF3, 0xF3)));
        Notice = Brush(dark ? 0xFF9F0A : 0xA65200);
        Critical = Brush(dark ? 0xFF453A : 0xD70015);
        StaleColor = Rgb(0x8E8E93);
        Fresh = Brush(dark ? 0x30D158 : 0x248A3D);
    }

    public SolidColorBrush Primary { get; }
    public SolidColorBrush Secondary { get; }
    public SolidColorBrush Tertiary { get; }
    public SolidColorBrush CardFill { get; }
    public SolidColorBrush CardBorder { get; }
    public SolidColorBrush ControlFill { get; }
    public SolidColorBrush ControlPressed { get; }
    /// <summary>不透明的面板底色（沒有 Acrylic 時；截圖也用這個）</summary>
    public SolidColorBrush Solid { get; }
    public SolidColorBrush Notice { get; }
    public SolidColorBrush Critical { get; }
    public SolidColorBrush Fresh { get; }
    public Color StaleColor { get; }

    /// <summary>服務識別色：深色為原色，淺色調暗（UsagePalette.provider）</summary>
    public Color ProviderColor(string key) => key switch
    {
        "claude" => Rgb(Dark ? 0xD97757 : 0xB4532F),
        "codex" => Rgb(Dark ? 0x5CC2B1 : 0x237A6B),
        _ => Rgb(Dark ? 0x9AAAC8 : 0x4A5D80),
    };

    /// <summary>進度條與外圈的顏色（FR-16）：過期灰、剩 &lt; 20% 紅、其他為服務識別色</summary>
    public Color BarColor(string provider, RingState state) => state switch
    {
        RingState.Stale => StaleColor,
        RingState.Critical => Critical.Color,
        _ => ProviderColor(provider),
    };

    public Color BarColor(UsageWindow window, string provider, bool stale, DateTimeOffset now) =>
        stale ? StaleColor : window.EffectiveSeverity(now) == UsageSeverity.Critical ? Critical.Color : ProviderColor(provider);

    public static Color Rgb(int hex) => Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);

    public static SolidColorBrush Brush(int hex) => Freeze(new SolidColorBrush(Rgb(hex)));

    public static SolidColorBrush Brush(Color color, double opacity) =>
        Freeze(new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * opacity), color.R, color.G, color.B)));

    private static SolidColorBrush Freeze(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }
}

/// <summary>系統的外觀設定：深淺色、透明效果、高對比、「顯示動畫」。</summary>
internal static class SystemLook
{
    private const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>截圖時固定（--render），不讀系統</summary>
    public static bool? ForcedDark { get; set; }

    public static bool IsDark(Appearance appearance) => appearance switch
    {
        Appearance.Dark => true,
        Appearance.Light => false,
        _ => ForcedDark ?? AppsUseDarkTheme(),
    };

    public static bool AppsUseDarkTheme() => ReadPersonalize("AppsUseLightTheme") == 0;

    /// <summary>工作列與系統匣的深淺色（「Windows 模式」，和 App 的可以不同；Windows 11 預設深色）</summary>
    public static bool TaskbarIsDark => ForcedDark ?? ReadPersonalize("SystemUsesLightTheme") != 1;

    /// <summary>「透明效果」開著且不是高對比：面板才用 Acrylic</summary>
    public static bool TransparencyEnabled => ReadPersonalize("EnableTransparency") != 0 && !SystemParameters.HighContrast;

    /// <summary>設定 › 協助工具 › 視覺效果 › 動畫效果（SPI_GETCLIENTAREAANIMATION）</summary>
    public static bool AnimationsEnabled => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;

    /// <summary>Windows 11 22H2（22621）起才有 DWMWA_SYSTEMBACKDROP_TYPE</summary>
    public static bool SupportsBackdrop => Environment.OSVersion.Version.Build >= 22621;

    private static int? ReadPersonalize(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Personalize);
            return key?.GetValue(name) is int value ? value : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI, Microsoft JhengHei UI");
    public static readonly FontFamily DisplayFont = new("Segoe UI Variable Display, Segoe UI, Microsoft JhengHei UI");
}
