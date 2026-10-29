using System.Text.Json;

namespace AIUsageMonitor.Core;

/// <summary>
/// 切回 AI 的程式就算看過（ADR-0017 第 8 節）：shared/agent-hosts.json 列出宿主程式（Mac 的 bundle ID、Windows 的執行檔名稱）
/// 與它代表的 AI。只比對程式識別，不讀視窗標題或內容；判斷規則在 <see cref="AgentSessions.MarkSeenByHost"/>。同 UsageKit/AgentHosts.swift
/// </summary>
public sealed class AgentHosts
{
    /// <summary>完成時宿主程式已經在前景：停留多久也算看過</summary>
    public const long DwellMs = 3_000;

    private readonly Dictionary<string, HashSet<AgentKind>> windows;

    private AgentHosts(Dictionary<string, HashSet<AgentKind>> windows) => this.windows = windows;

    public static AgentHosts None { get; } = new([]);

    /// <summary>讀 agent-hosts.json；格式不對時沒有宿主（功能關閉，其他照常）</summary>
    public static AgentHosts Decode(string json)
    {
        var map = new Dictionary<string, HashSet<AgentKind>>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var doc = JsonDocument.Parse(json);
            foreach (var host in doc.RootElement.GetProperty("hosts").EnumerateArray())
            {
                var ais = host.GetProperty("ais").EnumerateArray()
                    .Select(a => AgentNames.Kind(a.GetString())).OfType<AgentKind>().ToHashSet();
                if (ais.Count == 0 || !host.TryGetProperty("windows", out var names)) continue;
                foreach (var name in names.EnumerateArray())
                {
                    if (name.GetString() is not { Length: > 0 } exe) continue;
                    if (!map.TryGetValue(exe, out var set)) map[exe] = set = [];
                    set.UnionWith(ais);
                }
            }
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return None;
        }
        return new AgentHosts(map);
    }

    /// <summary>前景程式的執行檔名稱（只有檔名）代表哪些 AI；不是宿主就是空的</summary>
    public IReadOnlySet<AgentKind> Ais(string? exeName) =>
        exeName is not null && windows.TryGetValue(exeName, out var set) ? set : new HashSet<AgentKind>();
}
