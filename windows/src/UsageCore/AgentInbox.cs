using System.Globalization;
using System.Security.Cryptography;

namespace AIUsageMonitor.Core;

/// <summary>
/// Windows 的 hook 怎麼把事件交給 App（ADR-0019 第 1 節）：App 不能用 socket 或 named pipe（ADR-0015），所以 hook 把一個事件
/// 寫成一個小檔案到 <c>agent\inbox\</c>，App 依檔名（時間）排序處理、處理完刪掉。檔案內容就是 Mac 送到 socket 的那一行
/// （<see cref="AgentHookMessage"/>），只是資料夾名稱一律是空字串：Windows 上不顯示資料夾名稱，所以也不落地。
/// 這裡只放檔案的規則；具名 Mutex 與事件（判斷 App 在不在跑、叫醒 App）由呼叫端處理。
/// </summary>
public static class AgentInbox
{
    /// <summary>inbox 裡最多幾個檔：App 沒在處理時 hook 不再寫，不讓檔案堆積</summary>
    public const int MaxFiles = 256;
    /// <summary>鹽的長度（位元組）</summary>
    public const int SaltLength = 32;

    public static string AgentDirectory(string home) => Path.Combine(home, "agent");
    public static string InboxDirectory(string home) => Path.Combine(AgentDirectory(home), "inbox");
    public static string SaltPath(string home) => Path.Combine(AgentDirectory(home), "salt");

    /// <summary>工作階段 ID 加鹽的 SHA-256，取前 16 個十六進位字元（同 Swift 的 AgentSocket.sessionHash）</summary>
    public static string SessionHash(string sessionId, byte[] salt)
    {
        var id = System.Text.Encoding.UTF8.GetBytes(sessionId);
        var digest = SHA256.HashData([.. salt, .. id]);
        return Convert.ToHexStringLower(digest)[..16];
    }

    public static byte[]? ReadSalt(string home)
    {
        try
        {
            var data = File.ReadAllBytes(SaltPath(home));
            return data.Length == SaltLength ? data : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>App 啟動時：沒有鹽就建一個（%LOCALAPPDATA% 底下，只有使用者自己能讀）</summary>
    public static byte[] EnsureSalt(string home)
    {
        if (ReadSalt(home) is { } salt) return salt;
        Directory.CreateDirectory(AgentDirectory(home));
        salt = RandomNumberGenerator.GetBytes(SaltLength);
        var temp = SaltPath(home) + "." + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4)) + ".tmp";
        File.WriteAllBytes(temp, salt);
        File.Move(temp, SaltPath(home), overwrite: true);
        return salt;
    }

    /// <summary>檔名：UTC 時間（100 奈秒刻度，補零到 20 位）＋ 8 個隨機十六進位字元。依名稱排序就是依時間</summary>
    public static string FileName(DateTimeOffset now, string random) =>
        now.UtcTicks.ToString("D20", CultureInfo.InvariantCulture) + "-" + random + ".json";

    /// <summary>
    /// hook 端：把事件寫進 inbox。資料夾名稱一律不寫；沒有鹽（App 沒跑過）、inbox 已滿或任何錯誤都安靜地回傳 false
    /// </summary>
    public static bool Write(string home, AgentKind ai, byte[] input, DateTimeOffset now)
    {
        try
        {
            if (AgentHookInput.Extract(input) is not { } e || ReadSalt(home) is not { } salt) return false;
            var inbox = InboxDirectory(home);
            if (!Directory.Exists(inbox)) return false;
            if (Directory.EnumerateFiles(inbox).Take(MaxFiles).Count() >= MaxFiles) return false;
            var message = new AgentHookMessage(ai, e.Event, e.Need, SessionHash(e.SessionId, salt), now.ToUnixTimeMilliseconds(), "", e.Sub);
            var name = FileName(now, Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4)));
            var temp = Path.Combine(inbox, "." + name + ".tmp");
            File.WriteAllBytes(temp, message.Encoded());
            File.Move(temp, Path.Combine(inbox, name));
            return true;
        }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>
    /// App 端：依檔名排序讀出 inbox 的事件並刪掉。格式不合的直接刪；刪不掉的（防毒軟體暫時鎖住）留到下次，
    /// 由 <paramref name="seen"/> 記住已經處理過、不重複套用。寫到一半的暫存檔（.開頭）不碰
    /// </summary>
    public static List<AgentHookMessage> Drain(string home, HashSet<string> seen)
    {
        var result = new List<AgentHookMessage>();
        string[] files;
        try { files = Directory.GetFiles(InboxDirectory(home), "*.json"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return result; }
        var names = files.Select(Path.GetFileName).OfType<string>().Where(n => !n.StartsWith('.')).Order(StringComparer.Ordinal).ToList();
        foreach (var name in names)
        {
            var path = Path.Combine(InboxDirectory(home), name);
            if (!seen.Contains(name))
            {
                // 讀不到（被鎖住）：下次再試；讀到了但格式不合：當成處理過，直接刪
                if (Read(path) is not { } data) continue;
                if (AgentHookMessage.Parse(data) is { Folder: "" } message) result.Add(message);
                seen.Add(name);
            }
            try { File.Delete(path); seen.Remove(name); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        // 已經不在的檔不必再記
        seen.IntersectWith(names);
        return result;
    }

    /// <summary>App 啟動與結束時：inbox 清空（啟動時先 Drain 處理再清）</summary>
    public static void Clear(string home)
    {
        try
        {
            foreach (var path in Directory.GetFiles(InboxDirectory(home)))
            {
                try { File.Delete(path); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static byte[]? Read(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            // 太大的不讀內容：回傳空的，當成格式不合刪掉
            if (stream.Length > AgentHookMessage.MaxLength) return [];
            var buffer = new byte[stream.Length];
            stream.ReadExactly(buffer);
            return buffer;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}
