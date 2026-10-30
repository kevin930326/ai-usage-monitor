using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using AIUsageMonitor.Core;
using AIUsageMonitor.Mascot;
using SkiaSharp;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 設定的「角色外觀」（icons 第 8 部分第 3 項，同 Mac 的 MascotLookPicker）：每個外觀用實際的角色畫一格預覽
/// （大的是展開時、小的是收合時的迷你角色），依分組（基本、科技、可愛、極簡、特效）排好，點一下選。
/// 預覽是靜態的一格，設定頁開著也不重畫。
/// </summary>
internal sealed class MascotLookPicker : StackPanel
{
    /// <summary>一格預覽的大小（DIP，同 Mac）</summary>
    public const double TileWidth = 72, TileHeight = 52;

    private readonly List<(string? Id, Border Frame, Button Button)> tiles = [];
    private string? selected;

    public MascotLookPicker(MascotConfig config, MascotLooks looks, MascotCharacter character, string? selected, Action<string?> select)
    {
        this.selected = selected;
        var groups = looks.Groups
            .Select(g => (g.Name, Items: looks.Looks.Where(l => l.Group == g.Id).Cast<MascotLook?>().ToList()))
            .Where(g => g.Items.Count > 0)
            .ToList();
        // 「跟著服務」放在第一組的第一格（同 Mac 排在最前面）
        if (groups.Count == 0) groups.Add(("", []));
        groups[0].Items.Insert(0, null);
        foreach (var (name, items) in groups)
        {
            if (name.Length > 0)
            {
                Children.Add(new TextBlock { Text = name, Opacity = 0.7, FontSize = 12, Margin = new Thickness(0, 6, 0, 2) });
            }
            var row = new WrapPanel();
            foreach (var look in items) row.Children.Add(Tile(config, looks, character, look, select));
            Children.Add(row);
        }
        Mark();
    }

    /// <summary>目前選的外觀（外部改了設定時，例如右鍵選單，用這個同步）</summary>
    public string? Selected
    {
        get => selected;
        set
        {
            selected = value;
            Mark();
        }
    }

    private Button Tile(MascotConfig config, MascotLooks looks, MascotCharacter character, MascotLook? look, Action<string?> select)
    {
        var frame = new Border
        {
            Width = TileWidth,
            Height = TileHeight,
            CornerRadius = new CornerRadius(10),
            Background = Brushes.Black,
            BorderThickness = new Thickness(2),
            Child = new Image { Source = Preview(config, character, look, TileWidth, TileHeight, 2), Stretch = Stretch.Fill },
        };
        var label = new TextBlock { Text = look?.Name ?? "跟著服務", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        var stack = new StackPanel();
        stack.Children.Add(frame);
        stack.Children.Add(label);
        var button = new Button
        {
            Content = stack,
            Padding = new Thickness(0),
            Margin = new Thickness(0, 0, 8, 8),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ToolTip = look is null ? "Claude 是珊瑚色、Codex 是青瓷色" : $"{GroupName(looks, look)}・{Describe(look)}",
        };
        button.Tag = look is null
            ? $"跟著服務：{(character == MascotCharacter.Codex ? "Codex" : "Claude")} 的服務色"
            : $"{GroupName(looks, look)}：{look.Name}，{Describe(look)}";
        var id = look?.Id;
        button.Click += (_, _) =>
        {
            if (selected == id) return;
            Selected = id;
            select(id);
        };
        tiles.Add((id, frame, button));
        return button;
    }

    private void Mark()
    {
        foreach (var (id, frame, button) in tiles)
        {
            var on = id == selected;
            if (on) frame.SetResourceReference(Border.BorderBrushProperty, SystemColors.AccentColorBrushKey);
            else frame.BorderBrush = Brushes.Transparent;
            // 朗讀程式念出「已選取」（Button 沒有選取狀態）：寫在名稱後面
            var name = (string)button.Tag;
            AutomationProperties.SetName(button, on ? $"{name}（已選取）" : name);
        }
    }

    private static string GroupName(MascotLooks looks, MascotLook look) => looks.Groups.FirstOrDefault(g => g.Id == look.Group)?.Name ?? "";

    /// <summary>朗讀與滑鼠提示（同 Mac MascotLookPicker.describe）</summary>
    public static string Describe(MascotLook look) => look.Style switch
    {
        MascotLookStyle.Solid or MascotLookStyle.Linear => look.Blush ? "有腮紅" : look.Eye is not null ? "深色身體、亮色眼睛" : "單色",
        MascotLookStyle.Led => "琥珀色 LED 點陣，有一道掃描光",
        MascotLookStyle.Pixel => "大格子像素、三階明暗",
        MascotLookStyle.Neon => "發光的外框，會呼吸",
        MascotLookStyle.Wire => "經緯線組成的球，會慢慢轉",
        _ => "用字元畫的，字元會微微跳動",
    };

    /// <summary>
    /// 一格靜態預覽（透明底，同 Mac MascotLookPreview）：左邊展開時的角色（半徑 16），右下收合時的迷你角色（半徑 9）。
    /// width、height 是 DIP；ppd 是每 DIP 的像素數
    /// </summary>
    public static BitmapSource Preview(MascotConfig config, MascotCharacter character, MascotLook? look, double width, double height, double ppd)
    {
        int w = (int)Math.Ceiling(width * ppd), h = (int)Math.Ceiling(height * ppd);
        using var bitmap = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(bitmap))
        {
            canvas.Clear(SKColors.Transparent);
            canvas.Scale((float)ppd);
            var painter = new MascotPainter(config) { CanvasWidth = width, PanelHeight = height };
            var pose = new MascotScripts(config).CardPose;
            foreach (var (x, y, r) in new[] { (width * 0.38, height * 0.5, 16.0), (width - 13, height - 12, 9.0) })
            {
                var placed = pose.With(new Dictionary<MascotProp, double>
                {
                    [MascotProp.X] = x, [MascotProp.Y] = y, [MascotProp.R] = r, [MascotProp.Glow] = r > 12 ? 0.35 : 0, [MascotProp.Hands] = 0,
                });
                painter.DrawHero(new MascotFrame { Time = 0, Pose = placed, Character = character, Look = look }, canvas);
            }
        }
        var image = BitmapSource.Create(w, h, 96 * ppd, 96 * ppd, PixelFormats.Pbgra32, null, bitmap.GetPixels(), bitmap.ByteCount, bitmap.RowBytes);
        image.Freeze();
        return image;
    }
}
