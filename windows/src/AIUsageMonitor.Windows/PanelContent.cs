using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Documents;
using System.Windows.Media;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>面板內容需要的資料（截圖與實際面板共用）</summary>
internal sealed record PanelModel(UsageSnapshot? Snapshot, string? Error, DateTimeOffset Now, RefreshOutcome? Hint, MascotLevel? Level = null);

/// <summary>
/// 面板的內容（Mac 面板的頁首、主圓環卡片、額度卡片，ADR-0008 第 2 節、設計 skill 第 9 節）：寬 360、卡片圓角 12、
/// 半透明填色（主要文字色 4.5%）加細邊框。文字一律主要／次要文字色，顏色只用在圓環、進度條、服務圖示與提示文字。
/// 控制項自己畫，截圖（RenderTargetBitmap）才畫得出來。
/// </summary>
internal sealed class PanelContent : Border
{
    public const double PanelWidth = 360;
    private const string IconFont = "Segoe Fluent Icons, Segoe MDL2 Assets";

    private readonly Palette p;
    private readonly List<DualRingElement> rings = [];
    private readonly List<QuotaBarElement> bars = [];
    private readonly List<(TextBlock Text, double Value)> numbers = [];

    public event Action? RefreshRequested;
    public event Action? SettingsRequested;
    public event Action? QuitRequested;
    /// <summary>點了事故那行（參數是 IncidentLink 檢查過的事故頁）</summary>
    public event Action<string>? IncidentRequested;

    public PanelContent(PanelModel model, Palette palette)
    {
        p = palette;
        Width = PanelWidth;
        Padding = new Thickness(16, 14, 16, 16);
        TextElement.SetFontFamily(this, SystemLook.Font);
        TextElement.SetForeground(this, p.Primary);
        var stack = new StackPanel();
        stack.Children.Add(Header(model));
        if (model.Hint is { } hint)
        {
            stack.Children.Add(Text(RefreshHint.Text(hint), 12, RefreshHint.IsProblem(hint) ? p.Notice : p.Secondary, margin: new Thickness(0, 6, 0, 0), wrap: true));
        }
        foreach (var card in Cards(model)) stack.Children.Add(card);
        Child = stack;
    }

    /// <summary>打開面板時的描繪進度 0…1（主圓環、進度條、百分比數字）</summary>
    public void SetAppear(double appear)
    {
        foreach (var r in rings) r.Appear = appear;
        foreach (var b in bars) b.Appear = appear;
        foreach (var (text, value) in numbers) text.Text = SwiftMath.Round(value * appear).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>預期進度標記的淡入 0…1</summary>
    public void SetMarker(double opacity)
    {
        foreach (var b in bars) b.MarkerOpacity = opacity;
    }

    // ---------- 頁首 ----------

    private UIElement Header(PanelModel model)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text("AI 用量", 20, p.Primary, FontWeights.Bold);
        title.FontFamily = SystemLook.DisplayFont;
        title.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(title);
        if (model.Snapshot is { } snapshot)
        {
            var status = UpdatedStatus(snapshot, model.Now);
            Grid.SetColumn(status, 1);
            grid.Children.Add(status);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        buttons.Children.Add(IconButton("", "立即更新（請收集器現在執行）", () => RefreshRequested?.Invoke()));
        buttons.Children.Add(IconButton("", "設定", () => SettingsRequested?.Invoke()));
        buttons.Children.Add(IconButton("", "結束 AI Usage Monitor", () => QuitRequested?.Invoke()));
        Grid.SetColumn(buttons, 2);
        grid.Children.Add(buttons);
        return grid;
    }

    /// <summary>綠點＋「12分鐘前更新」；過期時灰點＋「資料已過期 · 09:30 更新」（提示色，FR-11）</summary>
    private UIElement UpdatedStatus(UsageSnapshot snapshot, DateTimeOffset now)
    {
        var stale = snapshot.IsStale(now);
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 2, 4, 0) };
        row.Children.Add(Dot(stale ? new SolidColorBrush(p.StaleColor) : p.Fresh, 7, new Thickness(0, 0, 5, 0)));
        var text = stale ? RingText.Updated(snapshot, now, TimeZoneInfo.Local) : ResetCountdown.UpdatedText(snapshot.UpdatedAt, now);
        var label = Text(text, 12, stale ? p.Notice : p.Secondary);
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        row.Children.Add(label);
        return row;
    }

    private Button IconButton(string glyph, string help, Action action)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = glyph, FontFamily = new FontFamily(IconFont), FontSize = 13, Foreground = p.Primary },
            Width = 28,
            Height = 28,
            Margin = new Thickness(4, 0, 0, 0),
            ToolTip = help,
            Cursor = Cursors.Hand,
            Template = PlainButton(p.ControlFill, p.ControlPressed, 7),
            Focusable = true,
        };
        System.Windows.Automation.AutomationProperties.SetName(button, help);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>自己畫的按鈕外觀：圓角底色，按下時深一點、鍵盤焦點時加外框</summary>
    public static ControlTemplate PlainButton(Brush fill, Brush pressed, double radius)
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "Back");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        border.SetValue(Border.BackgroundProperty, fill);
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1.5));
        border.SetValue(Border.BorderBrushProperty, Brushes.Transparent);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        template.VisualTree = border;
        var press = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(Border.BackgroundProperty, pressed, "Back"));
        template.Triggers.Add(press);
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, pressed, "Back"));
        template.Triggers.Add(hover);
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, SystemColors.HighlightBrush, "Back"));
        template.Triggers.Add(focus);
        return template;
    }

    // ---------- 卡片 ----------

    private IEnumerable<UIElement> Cards(PanelModel model)
    {
        if (model.Snapshot is not { } snapshot)
        {
            // 沒有資料或讀不到：說明怎麼讓收集器寫出 usage.json
            var body = new StackPanel();
            body.Children.Add(Text(model.Error is null ? "還沒有額度資料" : "無法讀取額度資料", 13, p.Primary, FontWeights.SemiBold));
            body.Children.Add(Text(model.Error is null
                ? "在 PowerShell（repo 的 collector 資料夾）執行 windows\\install-task.ps1 -WithQuota，收集器 5 分鐘內寫出資料。"
                : model.Error, 12, model.Error is null ? p.Secondary : p.Notice, margin: new Thickness(0, 4, 0, 0), wrap: true));
            body.Children.Add(Text(DataPaths.Usage, 11, p.Tertiary, margin: new Thickness(0, 6, 0, 0), wrap: true));
            yield return Card(body);
            // 只收集 Token（--tokens-only，ADR-0011）時沒有額度資料，但有歷史就有等級（Codex C-01）
            if (model.Level is { } only) yield return LevelCard(only);
            yield break;
        }
        var now = model.Now;
        var stale = snapshot.IsStale(now);
        if (snapshot.TightestWindow(now) is { } item) yield return RingCard(item, stale, now);
        yield return QuotaCard(snapshot, stale, now);
        if (model.Level is { } level) yield return LevelCard(level);
    }

    /// <summary>
    /// 角色等級（ADR-0020 第 4 節，2026-10-29 修訂）：Windows 只算這台電腦（不為了等級存讀取密鑰），標題列右邊寫「這台電腦」。
    /// 「Lv 7」、細的進度條、「連續 5 天・最長 12 天」；沒有任何活躍日時不顯示。
    /// </summary>
    private UIElement LevelCard(MascotLevel level)
    {
        var header = new DockPanel();
        var scope = Text("這台電腦", 11, p.Tertiary);
        DockPanel.SetDock(scope, Dock.Right);
        header.Children.Add(scope);
        header.Children.Add(Text("角色等級", 12, p.Secondary, FontWeights.SemiBold));

        var body = new StackPanel();
        var top = new DockPanel();
        var streak = Text(level.StreakText, 12, p.Secondary);
        streak.VerticalAlignment = VerticalAlignment.Bottom;
        streak.FontFeatures();
        DockPanel.SetDock(streak, Dock.Right);
        top.Children.Add(streak);
        var title = Text(level.Title, 17, p.Primary, FontWeights.SemiBold);
        title.FontFeatures();
        top.Children.Add(title);
        body.Children.Add(top);
        var track = new Grid { Height = 4, Margin = new Thickness(0, 6, 0, 0) };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Clamp(level.Progress, 0, 1), GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - Math.Clamp(level.Progress, 0, 1), GridUnitType.Star) });
        var rail = new Border { Background = p.ControlFill, CornerRadius = new CornerRadius(2) };
        Grid.SetColumnSpan(rail, 2);
        track.Children.Add(rail);
        track.Children.Add(new Border { Background = p.Secondary, CornerRadius = new CornerRadius(2) });
        body.Children.Add(track);

        var card = Card(body, header);
        card.ToolTip = level.ThisComputerText;
        System.Windows.Automation.AutomationProperties.SetName(card, level.ThisComputerText);
        return card;
    }

    private Border Card(UIElement content, UIElement? header = null)
    {
        var stack = new StackPanel();
        if (header is not null)
        {
            stack.Children.Add(header);
            if (content is FrameworkElement fe) fe.Margin = new Thickness(0, 10, 0, 0);
        }
        stack.Children.Add(content);
        return new Border
        {
            Child = stack,
            Padding = new Thickness(14),
            Margin = new Thickness(0, 12, 0, 0),
            CornerRadius = new CornerRadius(12),
            Background = p.CardFill,
            BorderBrush = p.CardBorder,
            BorderThickness = new Thickness(1),
        };
    }

    /// <summary>主圓環卡片：標題列放服務圖示＋「Claude 每週」；內容是雙圓環、大數字、重置倒數、會用完時的預測</summary>
    private UIElement RingCard(ProviderWindow item, bool stale, DateTimeOffset now)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(Icon(item.Provider, stale));
        header.Children.Add(Text(item.DisplayName, 13, p.Primary, FontWeights.SemiBold, new Thickness(6, 0, 0, 0)));

        var content = RingContent.From(item, stale, now, isLeast: true);
        var ring = new DualRingElement(content, p);
        rings.Add(ring);
        System.Windows.Automation.AutomationProperties.SetName(ring, item.LeastRemainingAccessibilityLabel(now));

        var remaining = item.Window.EffectiveRemainingPct(now);
        var number = Text(SwiftMath.Round(remaining).ToString(CultureInfo.InvariantCulture), 40, stale ? p.Secondary : p.Primary, FontWeights.Bold);
        number.FontFamily = SystemLook.DisplayFont;
        numbers.Add((number, remaining));
        var percent = new StackPanel { Orientation = Orientation.Horizontal };
        percent.Children.Add(number);
        percent.Children.Add(Text("%", 18, stale ? p.Secondary : p.Primary, FontWeights.SemiBold, new Thickness(1, 0, 0, 7)));
        ((TextBlock)percent.Children[1]).VerticalAlignment = VerticalAlignment.Bottom;

        var right = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
        right.Children.Add(percent);
        right.Children.Add(Text("剩餘 · " + ResetText(item.Window, now), 12, p.Secondary));
        if (ForecastOrTooFast(item.Window, stale, now, 4) is { } note) right.Children.Add(note);

        // DockPanel：右欄拿到剩下的寬度，預測那一行太長時換行，不會被切掉（橫向 StackPanel 給的寬度沒有上限）
        var row = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(ring, Dock.Left);
        row.Children.Add(ring);
        row.Children.Add(right);
        return Card(row, header);
    }

    /// <summary>
    /// 「照目前速度約 14:32 用完・比平常快 2.1 倍」（ADR-0018 第 3 節）：不到 60 分鐘紅色、其他提示色；顏色以外一律有文字。
    /// 取代原本的「用得較快，約 N 分鐘後用完」。
    /// </summary>
    /// <summary>
    /// 有預測時顯示預測；沒有預測但圓環是「太快」（平均速度）時只寫「用得較快」，不猜時間；其他不顯示
    /// </summary>
    private UIElement? ForecastOrTooFast(UsageWindow window, bool stale, DateTimeOffset now, double top) =>
        QuotaForecast.Current(window, stale, now) is { } forecast ? ForecastLine(forecast, now, top)
        : UsagePace.Average(window, stale, now)?.IsTooFast == true
            ? Text("用得較快", 12, p.Notice, FontWeights.Medium, new Thickness(0, top, 0, 0))
            : null;

    private UIElement ForecastLine(QuotaForecast forecast, DateTimeOffset now, double top)
    {
        var line = Text((forecast.Urgent ? "⚠ " : "") + forecast.Line(now), 12, forecast.Urgent ? p.Critical : p.Notice, FontWeights.Medium,
                        new Thickness(0, top, 0, 0), wrap: true);
        System.Windows.Automation.AutomationProperties.SetName(line, forecast.SpokenLine(now));
        return line;
    }

    /// <summary>
    /// 事故那行（ADR-0018 第 4 節）。有合法的事故頁（<see cref="IncidentLink"/>）時整行是按鈕：點了或按 Enter／空白鍵用預設瀏覽器打開
    /// （ADR-0015 第 2 節的例外）；右邊加「↗」（另一個文字，名稱太長被截掉時也看得到），滑鼠提示與朗讀的說明寫「在瀏覽器打開事故頁」。
    /// 沒有連結時只顯示文字。名稱最多兩行，超過的以省略號結尾。
    /// </summary>
    private UIElement IncidentLine(ServiceIncident incident)
    {
        var name = "服務異常：" + incident.Name;
        var line = Text(name, 12, p.Notice, FontWeights.Medium, wrap: true);
        line.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        line.LineHeight = 16;
        line.MaxHeight = 32;
        line.TextTrimming = TextTrimming.CharacterEllipsis;
        if (incident.Link is not { } link)
        {
            line.Margin = new Thickness(0, 6, 0, 0);
            System.Windows.Automation.AutomationProperties.SetName(line, name);
            return line;
        }
        var arrow = Text("↗", 12, p.Notice, FontWeights.Medium, new Thickness(4, 0, 0, 0));
        DockPanel.SetDock(arrow, Dock.Right);
        var content = new DockPanel { LastChildFill = true };
        content.Children.Add(arrow);
        content.Children.Add(line);
        var button = new Button
        {
            Content = content,
            Template = PlainButton(Brushes.Transparent, p.ControlFill, 6),
            HorizontalAlignment = HorizontalAlignment.Left,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(0),
            Margin = new Thickness(-4, 4, 0, 0),
            Cursor = Cursors.Hand,
            ToolTip = "在瀏覽器打開事故頁",
        };
        // PlainButton 的內容置中：外層留一點內距讓按下時的底色不貼字
        content.Margin = new Thickness(4, 2, 4, 2);
        // 名稱只放標籤，動作的說明放 HelpText（不然朗讀會把滑鼠提示再念一次）
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        System.Windows.Automation.AutomationProperties.SetHelpText(button, "在瀏覽器打開事故頁");
        button.Click += (_, _) => IncidentRequested?.Invoke(link);
        return button;
    }

    /// <summary>額度卡片：每個服務的名稱、方案、事故、各額度的進度條（含預期進度標記）、重置倒數與預測</summary>
    private UIElement QuotaCard(UsageSnapshot snapshot, bool stale, DateTimeOffset now)
    {
        var body = new StackPanel();
        var first = true;
        foreach (var key in snapshot.OrderedProviderKeys)
        {
            var provider = snapshot.Providers[key];
            var block = new StackPanel { Margin = new Thickness(0, first ? 0 : 14, 0, 0) };
            first = false;
            var title = new StackPanel { Orientation = Orientation.Horizontal };
            title.Children.Add(Icon(key, stale));
            title.Children.Add(Text(ProviderInfo.DisplayName(key), 13, p.Primary, FontWeights.SemiBold, new Thickness(6, 0, 0, 0)));
            if (provider.Plan is { } plan)
            {
                title.Children.Add(new Border
                {
                    Child = Text(plan, 10.5, p.Primary, FontWeights.SemiBold),
                    Background = p.ControlFill,
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(6, 0, 6, 1),
                    Margin = new Thickness(6, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            block.Children.Add(title);
            foreach (var incident in (provider.Incidents ?? []).Where(i => i.IsDisruption)) block.Children.Add(IncidentLine(incident));
            if (provider.Error is { } error)
            {
                var line = Text("⚠ " + error, 12, p.Notice, margin: new Thickness(0, 8, 0, 0), wrap: true);
                line.MaxHeight = 36;
                block.Children.Add(line);
            }
            else
            {
                foreach (var window in provider.VisibleWindows) block.Children.Add(QuotaRow(window, key, stale, now));
            }
            body.Children.Add(block);
        }
        if (snapshot.HasNoProviders)
        {
            body.Children.Add(Text(ProviderInfo.NoProvidersTitle, 12, p.Primary, FontWeights.SemiBold));
            body.Children.Add(Text(ProviderInfo.NoProvidersHint, 11, p.Secondary, margin: new Thickness(0, 2, 0, 0), wrap: true));
        }
        return Card(body, Text("額度", 12, p.Secondary, FontWeights.SemiBold));
    }

    private UIElement QuotaRow(UsageWindow window, string provider, bool stale, DateTimeOffset now)
    {
        var remaining = window.EffectiveRemainingPct(now);
        var row = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        var top = new DockPanel();
        var pct = Text($"{SwiftMath.Round(remaining).ToString(CultureInfo.InvariantCulture)}%", 13, p.Primary, FontWeights.SemiBold);
        pct.FontFeatures();
        DockPanel.SetDock(pct, Dock.Right);
        top.Children.Add(pct);
        top.Children.Add(Text(window.Label, 13, p.Primary));
        row.Children.Add(top);
        var bar = new QuotaBarElement(remaining / 100, window.ExpectedRemainingPct(now) is { } e ? e / 100 : null,
                                      p.BarColor(window, provider, stale, now), p) { Margin = new Thickness(0, 3, 0, 3) };
        bars.Add(bar);
        row.Children.Add(bar);
        row.Children.Add(Text(ResetText(window, now), 12, p.Secondary));
        if (ForecastOrTooFast(window, stale, now, 2) is { } note) row.Children.Add(note);
        System.Windows.Automation.AutomationProperties.SetName(row,
            $"{window.Label}，剩 {SwiftMath.Round(remaining)}%，{ResetText(window, now)}");
        return row;
    }

    /// <summary>「重置 2天 3小時」；時間已過為「已重置」（FR-26）；沒有重置時間時空白</summary>
    private static string ResetText(UsageWindow window, DateTimeOffset now)
    {
        if (window.IsReset(now)) return "已重置";
        return window.ResetsAt is { } r ? "重置 " + (ResetCountdown.Text(r, now) ?? "不到 1 分鐘") : "";
    }

    // ---------- 小元件 ----------

    private UIElement Icon(string provider, bool stale) =>
        new ProviderIconElement(provider, new SolidColorBrush(stale ? p.StaleColor : p.ProviderColor(provider)), 15) { VerticalAlignment = VerticalAlignment.Center };

    private static FrameworkElement Dot(Brush fill, double size, Thickness margin) =>
        new System.Windows.Shapes.Ellipse { Width = size, Height = size, Fill = fill, Margin = margin, VerticalAlignment = VerticalAlignment.Center };

    private static TextBlock Text(string text, double size, Brush brush, FontWeight? weight = null, Thickness? margin = null, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = brush,
        FontWeight = weight ?? FontWeights.Normal,
        Margin = margin ?? new Thickness(0),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
    };
}

internal static class TextBlockExtensions
{
    /// <summary>數字等寬（Mac 的 monospacedDigit）</summary>
    public static void FontFeatures(this TextBlock text) => Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);
}
