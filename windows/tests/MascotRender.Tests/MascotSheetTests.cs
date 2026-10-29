using AIUsageMonitor.Core;
using SkiaSharp;
using Xunit;

namespace AIUsageMonitor.Mascot.Tests;

/// <summary>
/// 角色的截圖（ADR-0015 第 1 節 2026-10-29 修訂）：用和 Mac 的 DebugMascot 相同的情境（固定時間、種子 7、視線置中）
/// 畫出對照圖，輸出到 build/win-mascot/；並把 Mac 的截圖基準（apple/Snapshots/mac/notch-*.png）放在左邊、
/// Windows 放在右邊，存成 compare-*.png 方便逐列比對。這裡只畫角色與瀏海外形（面板內容不在這個專案）。
/// </summary>
public class MascotSheetTests
{
    internal static string RepoRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null && !(Directory.Exists(Path.Combine(dir.FullName, "fixtures")) && Directory.Exists(Path.Combine(dir.FullName, "shared"))))
                dir = dir.Parent;
            return dir?.FullName ?? throw new DirectoryNotFoundException("找不到 repo 根目錄");
        }
    }

    internal static MascotConfig Config()
    {
        var config = MascotConfig.Decode(File.ReadAllText(Path.Combine(RepoRoot, "shared", "mascot-anim.json")));
        // Mac 截圖用沒有瀏海的假瀏海（寬 130）：迷你角色在 290 − 65 − 30
        return config with { Hero = config.Hero with { Mini = config.Hero.Mini with { X = 195, Y = 16 } } };
    }

    internal static MascotLooks Looks() => MascotLooks.Decode(File.ReadAllText(Path.Combine(RepoRoot, "shared", "mascot-looks.json")));

    private static string OutDir
    {
        get
        {
            var dir = Path.Combine(RepoRoot, "build", "win-mascot");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>LoopPhase：收合時的動態畫一輪的這個位置（0…1，同 Mac 的 loopPhase）</summary>
    internal sealed record Shot(string Name, Action<MascotDirector> Setup, long Time, MascotCharacter Character = MascotCharacter.Claude,
        MascotLook? Look = null, bool EffectsLive = false, double? LoopPhase = null);

    private const double Scale = 2;
    private static readonly SKColor Background = new(41, 41, 41);

    internal static MascotDirector Director(MascotConfig config, Shot shot)
    {
        var d = new MascotDirector(config, seed: 7, startTime: 0);
        shot.Setup(d);
        // 沒有指定表情時照額度（同 DebugMascot：額度資料正常，只看狀態等級）
        if (d.Mood == MascotMood.Normal) d.SetMood(MascotMoods.Quota(d.Machine.StatusLevel, unavailable: false));
        d.Advance(shot.Time);
        return d;
    }

    /// <summary>一格畫布（580 寬）：瀏海外形（黑色、下緣圓角）與角色</summary>
    internal static void DrawShot(SKCanvas canvas, MascotConfig config, Shot shot, double height)
    {
        var d = Director(config, shot);
        var t = shot.Time;
        var shape = d.PanelShape(t);
        using (var panel = new SKPaint { Color = SKColors.Black, IsAntialias = true })
        {
            var w = (float)shape.Width;
            var h = (float)Math.Min(shape.Height, height);
            var r = (float)Math.Min(shape.Corner, h / 2);
            using var rr = new SKRoundRect();
            rr.SetRectRadii(new SKRect(290 - w / 2, 0, 290 + w / 2, h), [new SKPoint(0, 0), new SKPoint(0, 0), new SKPoint(r, r), new SKPoint(r, r)]);
            canvas.DrawRoundRect(rr, panel);
        }
        var frame = MascotFrames.From(d, t, shot.Character, shot.Look, shot.EffectsLive ? t : null, gaze: (0, 0));
        if (shot.LoopPhase is { } phase
            && MascotCollapsedMotion.Plan(d, t, shot.Character, shot.Look, shot.EffectsLive ? t : null) is { } motion)
        {
            frame = motion.Frame((long)(phase * motion.Length));
        }
        new MascotPainter(config).Draw(frame, canvas, particles: true);
    }

    /// <summary>同 Mac 的 sheet：左右上下留 10、每格上面 14 高的名稱、間距 6</summary>
    internal static SKBitmap Sheet(MascotConfig config, IReadOnlyList<Shot> shots, double height, double? collapsedHeight = null)
    {
        double Row(Shot s) => s.Name.StartsWith("collapsed") ? collapsedHeight ?? height : height;
        var total = 20 + shots.Sum(s => 14 + 6 + Row(s)) + 6 * (shots.Count - 1);
        var bitmap = new SKBitmap((int)(600 * Scale), (int)Math.Round(total * Scale));
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(Background);
        canvas.Scale((float)Scale);
        using var font = new SKFont(SKTypeface.Default, 11);
        using var label = new SKPaint { Color = new SKColor(191, 191, 191), IsAntialias = true };
        double y = 10;
        foreach (var shot in shots)
        {
            canvas.DrawText(shot.Name, 10, (float)(y + 11), SKTextAlign.Left, font, label);
            y += 14 + 6;
            canvas.Save();
            canvas.Translate(10, (float)y);
            canvas.ClipRect(new SKRect(0, 0, 580, (float)Row(shot)));
            DrawShot(canvas, config, shot, Row(shot));
            canvas.Restore();
            y += Row(shot) + 6;
        }
        return bitmap;
    }

    private static void Save(SKBitmap bitmap, string name)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        File.WriteAllBytes(Path.Combine(OutDir, name), data.ToArray());
    }

    /// <summary>左邊 Mac 的截圖基準、右邊 Windows（中間 8 px 的間隔）</summary>
    private static void SaveComparison(SKBitmap windows, string macName)
    {
        Save(windows, macName);
        var macPath = Path.Combine(RepoRoot, "apple", "Snapshots", "mac", macName);
        if (!File.Exists(macPath)) return;
        using var mac = SKBitmap.Decode(macPath);
        using var both = new SKBitmap(mac.Width + 16 + windows.Width, Math.Max(mac.Height, windows.Height));
        using (var canvas = new SKCanvas(both))
        {
            canvas.Clear(SKColors.White);
            using var macImage = SKImage.FromBitmap(mac);
            canvas.DrawImage(macImage, 0, 0, SKSamplingOptions.Default);
            using var winImage = SKImage.FromBitmap(windows);
            canvas.DrawImage(winImage, mac.Width + 16, 0, SKSamplingOptions.Default);
        }
        Save(both, "compare-" + macName);
    }

    private static Shot Expression(string name, long offset, Action<MascotDirector> trigger) => new("expr-" + name, d =>
    {
        d.Open(0, intro: false);
        d.Advance(1000);
        trigger(d);
    }, 1000 + offset);

    internal static List<Shot> Expressions() =>
    [
        Expression("hop", 300, d => d.Request(MascotRequest.Hop, 1000)),
        Expression("wave", 700, d => d.Request(MascotRequest.Wave, 1000)),
        Expression("nod", 260, d => d.Request(MascotRequest.Nod, 1000)),
        Expression("tilt", 500, d => d.Request(MascotRequest.Tilt, 1000)),
        Expression("giggle", 400, d => d.Request(MascotRequest.Giggle, 1000)),
        Expression("look", 650, d => d.Request(MascotRequest.Look, 1000)),
        Expression("pinch", 250, d => d.Request(MascotRequest.Pinch, 1000)),
        Expression("dizzy", 1200, d => d.Request(MascotRequest.Dizzy, 1000)),
        Expression("shy", 700, d => d.Request(MascotRequest.Shy, 1000)),
        Expression("shy-peek", 1200, d => d.Request(MascotRequest.Shy, 1000)),
        Expression("scared", 700, d => d.Request(MascotRequest.Scared, 1000)),
        Expression("squeeze", 600, d => d.Press(1000)),
        Expression("sleep", 2000, d => d.SetAgentIdle(true, 1000)),
        Expression("wake", 2200, d => { d.SetAgentIdle(true, 1000); d.Click(2000, MascotRequest.Hop); }),
        Expression("work", 800, d => d.SetWorking(true, 1000)),
        Expression("alert-high", 250, d => d.SetStatus(1, 1000)),
        Expression("alert-out", 250, d => d.SetStatus(2, 1000)),
        new Shot("expr-collapsed-alert", d => d.SetStatus(1, 1000), 1350),
        .. Enum.GetValues<MascotMood>().Where(m => m != MascotMood.Normal)
            .Select(mood => Expression("face-" + MascotNames.Name(mood), 1000, d => d.RequestFace(mood, 1000))),
    ];

    [Fact]
    public void ExpressionsSheetMatchesMacLayout()
    {
        var config = Config();
        var shots = Expressions();
        using var sheet = Sheet(config, shots, 190);
        SaveComparison(sheet, "notch-expressions.png");
        using var mac = SKBitmap.Decode(Path.Combine(RepoRoot, "apple", "Snapshots", "mac", "notch-expressions.png"));
        // 列數與高度和 Mac 相同，並排時每一列對齊
        Assert.Equal(mac.Width, sheet.Width);
        Assert.Equal(mac.Height, sheet.Height);
    }

    [Fact]
    public void CollapsedAndIntroSheets()
    {
        var config = Config();
        var collapsed = new List<Shot>();
        foreach (var character in Enum.GetValues<MascotCharacter>())
            for (var level = 0; level <= 2; level++)
            {
                var l = level;
                collapsed.Add(new Shot($"collapsed-{character.Provider()}-{new[] { "normal", "high", "out" }[level]}", d => d.SetStatus(l, 0), 2000, character));
            }
        collapsed.Add(new Shot("collapsed-claude-low", d => d.SetStatus(1, 0), 2000));
        collapsed.Add(new Shot("collapsed-claude-stale", d => { d.SetStatus(0, 0); d.SetMood(MascotMood.Stale); }, 2000));
        foreach (var character in Enum.GetValues<MascotCharacter>())
            collapsed.Add(new Shot($"collapsed-{character.Provider()}-sleep", d => d.SetAgentIdle(true, 0), 2000, character));
        using (var sheet = Sheet(config, collapsed, 40)) SaveComparison(sheet, "notch-collapsed.png");
        // 跟著服務色：收合時敲鍵盤與睡著呼吸的幾格
        using (var sheet = Sheet(config, [
                   .. new[] { 0.0, 0.2, 0.4, 0.6 }.Select(p => new Shot($"collapsed-typing-{(int)(p * 100)}", d => d.SetWorking(true, 0), 2000, LoopPhase: p)),
                   .. new[] { 0.1, 0.35, 0.6, 0.85 }.Select(p => new Shot($"collapsed-doze-{(int)(p * 100)}", d => d.SetAgentIdle(true, 0), 2000, LoopPhase: p)),
               ], 40))
            SaveComparison(sheet, "notch-collapsed-motion.png");

        var expanded = Enum.GetValues<MascotCharacter>()
            .Select(c => new Shot($"expanded-{c.Provider()}", d => d.Open(0, intro: false), 1500, c)).ToList();
        expanded.Add(new Shot("expanded-claude-low", d => { d.SetStatus(1, 0); d.Open(0, intro: false); }, 1500));
        expanded.Add(new Shot("expanded-claude-stale", d => { d.SetMood(MascotMood.Stale); d.Open(0, intro: false); }, 1500));
        expanded.Add(new Shot("expanded-claude-out", d => { d.SetStatus(2, 0); d.Open(0, intro: false); }, 1500));
        var intro = new long[] { 0, 300, 1200, 2600, 3990, 4700 }.Select(ms => new Shot($"intro-{ms}", d => d.Open(0, intro: true), ms));
        using (var sheet = Sheet(config, [.. expanded, .. intro], 190)) SaveComparison(sheet, "notch-intro.png");
    }

    [Fact]
    public void LooksSheets()
    {
        var config = Config();
        var looks = Looks().Looks;
        using (var sheet = Sheet(config, looks.Select(l => new Shot($"expanded-look-{l.Id}", d => d.Open(0, intro: false), 1500,
                   Look: l, EffectsLive: l.Style.Animates())).ToList(), 190))
            SaveComparison(sheet, "notch-looks-expanded.png");
        // 收合：工作中（敲鍵盤＋思考泡泡，特效在動）、睡著（呼吸與小 z）、閒置（靜態）；動態都畫一輪的 0.3 處（同 Mac）
        using (var sheet = Sheet(config, looks.SelectMany(l => new[]
               {
                   new Shot($"collapsed-look-{l.Id}-work", d => d.SetWorking(true, 0), 2000, Look: l, EffectsLive: l.Style.Animates(), LoopPhase: 0.3),
                   new Shot($"collapsed-look-{l.Id}-sleep", d => d.SetAgentIdle(true, 0), 2000, Look: l, LoopPhase: 0.3),
                   new Shot($"collapsed-look-{l.Id}-idle", _ => { }, 2000, Look: l),
               }).ToList(), 40))
            SaveComparison(sheet, "notch-looks-collapsed.png");
    }

    [Fact]
    public void EveryLookAndMoodDrawsTheHero()
    {
        var config = Config();
        var painter = new MascotPainter(config);
        foreach (var look in Looks().Looks.Prepend(null))
        {
            foreach (var mood in Enum.GetValues<MascotMood>())
            {
                var d = Director(config, new Shot("x", x => x.Open(0, intro: false), 1500, Look: look));
                d.SetMood(mood);
                using var bitmap = new SKBitmap(580, 190);
                using var canvas = new SKCanvas(bitmap);
                canvas.Clear(SKColors.Black);
                painter.Draw(MascotFrames.From(d, 1500, MascotCharacter.Codex, look, 1500), canvas, particles: true);
                // 角色卡的中心一定畫了東西
                var card = config.Hero.Card;
                Assert.NotEqual(SKColors.Black, bitmap.GetPixel((int)card.X, (int)(card.Y + card.Radius * 0.6)));
            }
        }
    }
}
