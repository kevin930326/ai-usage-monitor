namespace AIUsageMonitor.Core;

/// <summary>
/// 事故頁連結（ADR-0015 第 2 節的例外、ADR-0018 第 4 節）：Windows App 唯一會交給預設瀏覽器的網址。
/// 整個字串必須剛好是 https://&lt;白名單網域&gt;/incidents/&lt;ID&gt;，ID 只有英數字、底線、連字號（1～64 字）；
/// 大小寫、空白、帳號、連接埠、查詢字串、片段、多一層路徑都不收。白名單是收集器實際查的兩個狀態頁（service_status.PAGES）。
/// 規則和 Swift 的 ServiceIncident.link 相同，fixtures/incident-links.json 兩邊比對。
/// 不用 Uri 解析（check-no-network.py 禁止），只做字串比對；這個檔案是 UsageCore 裡唯一允許出現網址的地方。
/// </summary>
public static class IncidentLink
{
    public static readonly string[] AllowedPrefixes =
    [
        "https://status.claude.com/incidents/",
        "https://status.openai.com/incidents/",
    ];

    /// <summary>符合規則時回傳原字串，否則 null</summary>
    public static string? Link(string? text)
    {
        if (text is null) return null;
        foreach (var prefix in AllowedPrefixes)
        {
            if (!text.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var id = text.AsSpan(prefix.Length);
            if (id.Length is < 1 or > 64) return null;
            foreach (var c in id)
                if (c is not ((>= '0' and <= '9') or (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or '-' or '_')) return null;
            return text;
        }
        return null;
    }
}
