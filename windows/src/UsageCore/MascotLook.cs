using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIUsageMonitor.Core;

// 角色外觀（ADR-0021）：shared/mascot-looks.json 的一個項目。和 Mac 的 UsageKit/MascotLook.swift 讀同一份檔案、
// 同樣的檢查。預設「跟著服務」不在清單裡（用服務色，null）。顏色是 0…255 的 sRGB 三元組。

/// <summary>solid 三階球面漸層、linear 直線漸層加高光與陰影；led、pixel、neon、wire、ascii 是特效</summary>
public enum MascotLookStyle { Solid, Linear, Led, Pixel, Neon, Wire, Ascii }

public static class MascotLookStyles
{
    public static bool IsEffect(this MascotLookStyle style) => style is not (MascotLookStyle.Solid or MascotLookStyle.Linear);

    /// <summary>格子類特效（LED 點陣、8-bit 像素、ASCII）：小圖示上改畫主色三階的實心球（ADR-0021 第 5 節）</summary>
    public static bool IsGrid(this MascotLookStyle style) => style is MascotLookStyle.Led or MascotLookStyle.Pixel or MascotLookStyle.Ascii;

    /// <summary>會隨時間變化的特效（像素是靜態的格子，不用重畫）</summary>
    public static bool Animates(this MascotLookStyle style) =>
        style is MascotLookStyle.Led or MascotLookStyle.Neon or MascotLookStyle.Wire or MascotLookStyle.Ascii;
}

public sealed record MascotLook
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Group { get; init; }
    public required MascotLookStyle Style { get; init; }
    public double[]? Light { get; init; }
    public double[]? Mid { get; init; }
    public double[]? Shade { get; init; }
    /// <summary>直線漸層的顏色（Linear）</summary>
    public IReadOnlyList<double[]>? Stops { get; init; }
    /// <summary>直線漸層的方向（度，0 是往右、90 是往下）</summary>
    public double? Angle { get; init; }
    /// <summary>特效的主色</summary>
    public double[]? Color { get; init; }
    public required double[] Glow { get; init; }
    /// <summary>光暈的強度倍數（霓虹較強）</summary>
    public double GlowScale { get; init; } = 1;
    /// <summary>眼睛的顏色；null 是深色 #121212（深色身體用亮色）</summary>
    public double[]? Eye { get; init; }
    /// <summary>可愛風的腮紅</summary>
    public bool Blush { get; init; }

    /// <summary>特效主色的三階（亮＝混白 60%、暗＝混黑 50%），手與像素的明暗用</summary>
    public (double[] Light, double[] Mid, double[] Shade)? EffectTint =>
        Color is { } c ? (c.Select(v => v + (255 - v) * 0.6).ToArray(), c, c.Select(v => v * 0.5).ToArray()) : null;
}

/// <summary>shared/mascot-looks.json 整份</summary>
public sealed record MascotLooks(int Version, IReadOnlyList<MascotLooks.LookGroup> Groups, IReadOnlyList<MascotLook> Looks)
{
    public sealed record LookGroup(string Id, string Name);

    private sealed record RawLook(
        [property: JsonPropertyName("id")] string? Id, [property: JsonPropertyName("name")] string? Name,
        [property: JsonPropertyName("group")] string? Group, [property: JsonPropertyName("style")] string? Style,
        [property: JsonPropertyName("light")] string? Light, [property: JsonPropertyName("mid")] string? Mid,
        [property: JsonPropertyName("shade")] string? Shade, [property: JsonPropertyName("stops")] string[]? Stops,
        [property: JsonPropertyName("angle")] double? Angle, [property: JsonPropertyName("color")] string? Color,
        [property: JsonPropertyName("glow")] string? Glow, [property: JsonPropertyName("glow_scale")] double? GlowScale,
        [property: JsonPropertyName("eye")] string? Eye, [property: JsonPropertyName("blush")] bool? Blush);

    private sealed record RawFile(
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("groups")] LookGroup[]? Groups,
        [property: JsonPropertyName("looks")] RawLook[]? Looks);

    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    /// <summary>解碼並檢查：顏色格式、每種樣式需要的顏色、代號不重複、分組存在（同 Swift）</summary>
    public static MascotLooks Decode(string json)
    {
        var file = JsonSerializer.Deserialize<RawFile>(json, Options) ?? throw new JsonException("mascot-looks.json 是空的");
        var groups = file.Groups ?? throw new JsonException("缺少 groups");
        var looks = (file.Looks ?? throw new JsonException("缺少 looks")).Select(Look).ToList();
        if (looks.Select(l => l.Id).Distinct().Count() != looks.Count) throw new JsonException("外觀代號重複");
        var groupIds = groups.Select(g => g.Id).ToHashSet();
        if (looks.FirstOrDefault(l => !groupIds.Contains(l.Group)) is { } stray) throw new JsonException($"{stray.Id} 的分組不存在");
        return new MascotLooks(file.Version, groups, looks);
    }

    private static MascotLook Look(RawLook raw)
    {
        var id = raw.Id ?? throw new JsonException("外觀缺少 id");
        var style = raw.Style switch
        {
            "solid" => MascotLookStyle.Solid,
            "linear" => MascotLookStyle.Linear,
            "led" => MascotLookStyle.Led,
            "pixel" => MascotLookStyle.Pixel,
            "neon" => MascotLookStyle.Neon,
            "wire" => MascotLookStyle.Wire,
            "ascii" => MascotLookStyle.Ascii,
            _ => throw new JsonException($"{id}：未知的樣式 {raw.Style}"),
        };
        var look = new MascotLook
        {
            Id = id,
            Name = raw.Name ?? throw new JsonException($"{id} 缺少 name"),
            Group = raw.Group ?? throw new JsonException($"{id} 缺少 group"),
            Style = style,
            Light = Optional(raw.Light),
            Mid = Optional(raw.Mid),
            Shade = Optional(raw.Shade),
            Stops = raw.Stops?.Select(Rgb).ToList(),
            Angle = raw.Angle,
            Color = Optional(raw.Color),
            Glow = Rgb(raw.Glow ?? throw new JsonException($"{id} 缺少 glow")),
            GlowScale = raw.GlowScale ?? 1,
            Eye = Optional(raw.Eye),
            Blush = raw.Blush ?? false,
        };
        var complete = style switch
        {
            MascotLookStyle.Solid => look.Light is not null && look.Mid is not null && look.Shade is not null,
            MascotLookStyle.Linear => (look.Stops?.Count ?? 0) >= 2,
            _ => look.Color is not null,
        };
        return complete ? look : throw new JsonException($"{id}：{raw.Style} 缺少顏色");
    }

    private static double[]? Optional(string? text) => text is null ? null : Rgb(text);

    /// <summary>「#RRGGBB」→ [r, g, b]；格式不對時解碼失敗（同 Swift 的 MascotLook.rgb）</summary>
    private static double[] Rgb(string text)
    {
        var hex = text.StartsWith('#') ? text[1..] : text;
        if (hex.Length != 6 || !hex.All(char.IsAsciiHexDigit)) throw new JsonException($"顏色格式不對：{text}");
        return MascotConfig.Rgb(hex);
    }

    public MascotLook? Look(string? id) => id is null ? null : Looks.FirstOrDefault(l => l.Id == id);
}
