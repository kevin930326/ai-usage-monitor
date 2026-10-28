using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

/// <summary>
/// 把 Windows 的 hook 合併進 Claude Code 的 <c>settings.json</c> 或 Codex 的 <c>hooks.json</c>（ADR-0019 第 1 節；規則同 Mac 的
/// UsageKit/AgentHookConfig.swift）：
/// <list type="bullet">
/// <item>只動我們的項目（指令含 <c>aum-hook.exe</c>）；別人的群組與 hook 一律保留。</item>
/// <item>重複安裝不會多一份：先拿掉我們舊的（含路徑已經不同的），再加上新的。</item>
/// <item>移除只刪我們的；某事件因此變空就刪掉該事件，<c>hooks</c> 因此變空就刪掉 <c>hooks</c>。</item>
/// <item>檔案不是 JSON 物件、或 <c>hooks</c> 不是物件時不改（丟出 <see cref="AgentHookConfigException"/>）。</item>
/// </list>
/// 鍵的順序保留；縮排改成兩格（<see cref="JsonObject"/> 不保留原本的空白，設定頁說明）。
/// </summary>
public static class AgentHookConfig
{
    /// <summary>認出我們的 hook 的字串（App 資料夾裡的程式名稱）</summary>
    public const string Marker = "aum-hook.exe";
    /// <summary>hook 的逾時（秒）：Codex 的 SessionEnd、Interrupt 最多允許 3 秒</summary>
    public const int TimeoutSeconds = 3;

    /// <summary>
    /// 路徑能不能放進設定：要是完整路徑、以 aum-hook.exe 結尾；不能有引號、控制字元或 cmd 的特殊字元
    /// （Codex 的 commandWindows 是一行指令，路徑只用雙引號包起來，ADR-0019 第 1 節）
    /// </summary>
    public static bool IsUsablePath(string path) =>
        path.Length is > 3 and < 260 && path.EndsWith(@"\" + Marker, StringComparison.OrdinalIgnoreCase)
        && path[1] == ':' && path[2] == '\\'
        && !path.Any(c => c < 0x20 || c is '"' or '%' or '^' or '&' or '|' or '<' or '>' or '!');

    /// <summary>
    /// 我們的一個 hook 項目。Claude Code 用 exec form（<c>args</c>，不經 Git Bash／PowerShell；找不到程式時 <c>onFailure</c>
    /// 讓 AI 照常繼續）；Codex 用 <c>commandWindows</c>（Windows 上用的那一行）
    /// </summary>
    public static JsonObject Handler(string exe, AgentKind ai) => ai == AgentKind.Claude
        ? new JsonObject
        {
            ["type"] = "command",
            ["command"] = exe,
            ["args"] = new JsonArray(AgentNames.Name(ai)),
            ["onFailure"] = "continue",
            ["timeout"] = TimeoutSeconds,
        }
        : new JsonObject
        {
            ["type"] = "command",
            ["command"] = CommandLine(exe, ai),
            ["commandWindows"] = CommandLine(exe, ai),
            ["timeout"] = TimeoutSeconds,
        };

    /// <summary>Codex 的一行指令：<c>"C:\…\aum-hook.exe" codex</c></summary>
    public static string CommandLine(string exe, AgentKind ai) => $"\"{exe}\" {AgentNames.Name(ai)}";

    public static bool IsOurs(JsonNode? handler) =>
        handler is JsonObject o
        && new[] { o["command"], o["commandWindows"] }.Any(n => AgentNames.Text(n)?.Contains(Marker, StringComparison.OrdinalIgnoreCase) == true);

    /// <summary>安裝或修好：回傳新的檔案內容（原本沒有檔案時傳 null）</summary>
    public static byte[] Install(byte[]? data, AgentKind ai, string exe, IReadOnlyList<AgentHookEvent>? events = null)
    {
        if (!IsUsablePath(exe)) throw new AgentHookConfigException("App 的位置含有不能放進設定檔的字元");
        var root = ParseRoot(data);
        var hooks = RemoveOurs(HooksObject(root));
        foreach (var e in events ?? AgentNames.Installed(ai))
        {
            var entry = new JsonObject { ["hooks"] = new JsonArray(Handler(exe, ai)) };
            var name = AgentNames.Name(e);
            if (hooks[name] is JsonArray groups) groups.Add(entry);
            else if (hooks.ContainsKey(name)) throw new AgentHookConfigException($"hooks.{name} 不是陣列");
            else hooks[name] = new JsonArray(entry);
        }
        SetHooks(root, hooks);
        return Serialize(root);
    }

    /// <summary>移除：回傳新的檔案內容；沒有我們的 hook 時回傳 null（不必寫檔）</summary>
    public static byte[]? Uninstall(byte[]? data)
    {
        if (data is null) return null;
        var root = ParseRoot(data);
        var hooks = HooksObject(root);
        var before = hooks.ToJsonString();
        var removed = RemoveOurs(hooks);
        if (removed.ToJsonString() == before) return null;
        SetHooks(root, removed);
        return Serialize(root);
    }

    /// <summary>目前的狀態（<paramref name="exe"/> 是目前 App 資料夾裡的 aum-hook.exe）</summary>
    public static AgentHookStatus Status(byte[]? data, AgentKind ai, string exe, IReadOnlyList<AgentHookEvent>? events = null)
    {
        if (data is null) return AgentHookStatus.NotInstalled;
        var hooks = HooksObject(ParseRoot(data));
        var expected = Handler(exe, ai).ToJsonString();
        var found = new HashSet<string>();
        var wrongPath = false;
        foreach (var (name, groups) in hooks)
        {
            foreach (var handler in Handlers(groups).Where(IsOurs))
            {
                found.Add(name);
                // 和目前 App 的不同：App 被移動、或是舊版本的寫法
                if (handler!.ToJsonString() != expected) wrongPath = true;
            }
        }
        if (found.Count == 0) return AgentHookStatus.NotInstalled;
        var missing = (events ?? AgentNames.Installed(ai)).Where(e => !found.Contains(AgentNames.Name(e))).ToList();
        return missing.Count == 0 && !wrongPath ? AgentHookStatus.Installed : new AgentHookStatus(true, missing, wrongPath);
    }

    private static JsonObject ParseRoot(byte[]? data)
    {
        if (data is null || data.All(b => b is 0x20 or 0x09 or 0x0A or 0x0D)) return new JsonObject();
        // 檔案開頭的 BOM（記事本存的 UTF-8）照樣可以讀
        var text = Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
        JsonNode? node;
        try { node = JsonNode.Parse(text, documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow }); }
        catch (JsonException) { throw new AgentHookConfigException("設定檔不是合法的 JSON"); }
        if (node is not JsonObject root) throw new AgentHookConfigException("設定檔最上層不是物件");
        try { _ = root.Count; }
        catch (ArgumentException) { throw new AgentHookConfigException("設定檔有重複的鍵"); }
        return root;
    }

    private static JsonObject HooksObject(JsonObject root) => root["hooks"] switch
    {
        null when !root.ContainsKey("hooks") => new JsonObject(),
        JsonObject hooks => hooks,
        _ => throw new AgentHookConfigException("hooks 不是物件"),
    };

    private static void SetHooks(JsonObject root, JsonObject hooks)
    {
        if (hooks.Count == 0) { root.Remove("hooks"); return; }
        if (hooks.Parent is null) root["hooks"] = hooks;
    }

    private static IEnumerable<JsonNode?> Handlers(JsonNode? groups) =>
        groups is JsonArray array
            ? array.OfType<JsonObject>().SelectMany(g => g["hooks"] is JsonArray handlers ? handlers : [])
            : [];

    /// <summary>拿掉每個事件裡我們的 hook；群組因此變空就拿掉群組，事件因此變空就拿掉事件（別人的原樣保留）</summary>
    private static JsonObject RemoveOurs(JsonObject hooks)
    {
        foreach (var name in hooks.Select(p => p.Key).ToList())
        {
            if (hooks[name] is not JsonArray groups) continue;   // 不是陣列：不是我們能懂的格式，原樣保留
            var touched = false;
            for (var i = groups.Count - 1; i >= 0; i--)
            {
                if (groups[i] is not JsonObject group || group["hooks"] is not JsonArray handlers) continue;
                var removed = false;
                for (var j = handlers.Count - 1; j >= 0; j--)
                {
                    if (!IsOurs(handlers[j])) continue;
                    handlers.RemoveAt(j);
                    removed = true;
                }
                if (removed && handlers.Count == 0) groups.RemoveAt(i);
                touched |= removed;
            }
            if (touched && groups.Count == 0) hooks.Remove(name);
        }
        return hooks;
    }

    private static byte[] Serialize(JsonObject root) =>
        Encoding.UTF8.GetBytes(root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            IndentSize = 2,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }) + "\n");
}

/// <summary>沒有、裝好了、或需要修好（缺事件或指向別的位置）</summary>
public sealed record AgentHookStatus(bool Present, IReadOnlyList<AgentHookEvent> Missing, bool WrongPath)
{
    public static readonly AgentHookStatus NotInstalled = new(false, [], false);
    public static readonly AgentHookStatus Installed = new(true, [], false);
    public bool NeedsRepair => Present && (Missing.Count > 0 || WrongPath);
}

/// <summary>設定檔的格式不是我們能安全修改的（畫面顯示訊息，不改檔案）</summary>
public sealed class AgentHookConfigException(string message) : Exception(message);
