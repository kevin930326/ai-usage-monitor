using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIUsageMonitor.Core;

/// <summary>
/// 角色等級的獨立檔案 level.json（ADR-0020 第 1 節，2026-10-29 修訂；MascotLevelLedger.swift）：App 把每天的主數字另存一份，
/// 只增不減。資料庫損毀重建、從備份還原或清除歷史讓 level_days 變少時，等級不會跟著變低。fixtures/level/ 的 golden 和 Swift 跑同一份。
/// <list type="bullet">
/// <item>格式：{"schema_version": 1, "xp": 123, "level": 3, "days": {"2026-10-29": 12345, …}}。xp、level 只是方便人看，讀取時以 days 重算。</item>
/// <item>合併：每一天取較大值；只留合法的 YYYY-MM-DD 而且 tokens &gt; 0 的日子。</item>
/// <item>讀取：不是 JSON 物件、沒有 days 物件時當成壞掉（null）；重複的鍵取第一個（和 Swift 相同），由呼叫端從歷史重算；days 裡格式不對的項目略過。
/// 數字只要剛好是整數就收（1.0、1e4 和 Swift 的 JSONDecoder 一樣當成整數），小數、超出範圍略過。</item>
/// </list>
/// </summary>
public static class MascotLevelLedger
{
    public const int SchemaVersion = 1;
    public const string FileName = "level.json";
    public const string CorruptName = "level.corrupt.json";

    private static readonly object Gate = new();

    /// <summary>每天取較大值</summary>
    public static Dictionary<string, long> Merge(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b)
    {
        var result = new Dictionary<string, long>();
        foreach (var source in new[] { a, b })
            foreach (var (day, tokens) in source)
                if (tokens > 0 && MascotLevel.DayNumber(day) is not null)
                    result[day] = Math.Max(result.GetValueOrDefault(day), tokens);
        return result;
    }

    /// <summary>讀 level.json 的內容；壞掉時 null</summary>
    public static Dictionary<string, long>? Decode(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind != JsonValueKind.Object || First(doc.RootElement, "days") is not { ValueKind: JsonValueKind.Object } days)
                return null;
            var result = new Dictionary<string, long>();
            foreach (var entry in days.EnumerateObject())
            {
                // 重複的日期取第一個（和 Swift 的 JSONDecoder 一樣；Fable F-02）。不是整數（字串、布林值、小數、超出範圍、null）時只略過這一天
                if (result.ContainsKey(entry.Name) || MascotLevel.DayNumber(entry.Name) is null) continue;
                if (entry.Value.ValueKind == JsonValueKind.Number && Integer(entry.Value) is > 0 and var tokens)
                    result[entry.Name] = tokens;
            }
            return result;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>物件裡第一個叫 name 的屬性（重複的鍵取第一個，和 Swift 一致）</summary>
    private static JsonElement? First(JsonElement obj, string name)
    {
        foreach (var p in obj.EnumerateObject())
            if (p.NameEquals(name)) return p.Value;
        return null;
    }

    /// <summary>剛好是整數的數字（1.0、1e4、2.5e4 都算，和 Swift 一致；Fable F-03）；小數、超出 long 時 null</summary>
    private static long? Integer(JsonElement value)
    {
        if (value.TryGetInt64(out var whole)) return whole;
        if (!value.TryGetDecimal(out var number) || number != decimal.Truncate(number)) return null;
        return number is >= long.MinValue and <= long.MaxValue ? (long)number : null;
    }

    /// <summary>寫入 level.json 的內容（日期排序，內容相同時文字相同）</summary>
    public static string Encode(IReadOnlyDictionary<string, long> days, string today)
    {
        var level = MascotLevel.From(days, today);
        var sorted = new JsonObject();
        foreach (var day in days.Keys.Order(StringComparer.Ordinal)) sorted[day] = days[day];
        var root = new JsonObject
        {
            ["days"] = sorted,
            ["level"] = level?.Level ?? 0,
            ["schema_version"] = SchemaVersion,
            ["xp"] = level?.Xp ?? 0,
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>Update 的結果：合併後的每一天；Saved 為 false 時 level.json 讀不到或寫不進去，Days 可能比檔案裡的少（Fable F-01、F-08）</summary>
    public sealed record Outcome(Dictionary<string, long> Days, bool Saved);

    /// <summary>
    /// 把 <paramref name="days"/>（歷史的 level_days，加上這次執行已經看過的日子）併進 <paramref name="path"/>。
    /// <list type="bullet">
    /// <item>檔案不在：從 days 建立。</item>
    /// <item>讀不懂（壞掉）：改名成 level.corrupt.json 保留（只留最近一份），從 days 重建（每天取較大值，所以不會比歷史低，
    /// 但檔案裡其他合法的日子只留在 level.corrupt.json）。</item>
    /// <item>讀不到（權限、被鎖住）：不改寫，回傳 days、Saved 為 false，下次再試。</item>
    /// <item>內容沒有變大就不改寫；寫入先寫暫存檔再取代（不會留下寫一半的檔案）。</item>
    /// </list>
    /// </summary>
    public static Outcome Update(string path, IReadOnlyDictionary<string, long> days, string today)
    {
        lock (Gate)
        {
            Dictionary<string, long> stored;
            var exists = File.Exists(path);
            try
            {
                stored = exists ? Decode(File.ReadAllText(path, Encoding.UTF8)) ?? Corrupt(path) : [];
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return new Outcome(Merge(days, new Dictionary<string, long>()), false);
            }
            var merged = Merge(stored, days);
            if (merged.Count == stored.Count && merged.All(p => stored.GetValueOrDefault(p.Key) == p.Value) && File.Exists(path))
                return new Outcome(merged, true);
            var temp = path + ".tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(temp, Encode(merged, today), new UTF8Encoding(false));
                File.Move(temp, path, overwrite: true);
                return new Outcome(merged, true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // 寫不了：這次照樣顯示合併後的等級，下次再寫；不留暫存檔（Fable F-10）
                try { File.Delete(temp); } catch (Exception d) when (d is IOException or UnauthorizedAccessException) { }
                return new Outcome(merged, false);
            }
        }
    }

    private static Dictionary<string, long> Corrupt(string path)
    {
        File.Move(path, Path.Combine(Path.GetDirectoryName(path)!, CorruptName), overwrite: true);
        return [];
    }
}
