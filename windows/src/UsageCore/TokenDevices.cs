namespace AIUsageMonitor.Core;

// 第二層：多裝置的 Token 統計（TokenDevices.swift，FR-49、ADR-0011 第 2、4 節）。
// 收集器（set-tier2.ps1 -ReadKey）從中繼下載其他電腦的每日加總，寫進 history.sqlite3（daily_tokens 的其他 device_id 與 devices 表）；
// 這裡只有範圍的篩選與標籤文字。Mac 的「這台 Mac」在 Windows 是「這台電腦」（ADR-0015 第 5 節）。

/// <summary>中繼上的一台電腦（devices 表）。IsSelf＝這台電腦自己（本機的數字以本機統計為準）。</summary>
public sealed record TokenDevice(string Id, string Name, DateTimeOffset? LastUpload = null, bool Revoked = false, bool IsSelf = false);

/// <summary>統計的裝置範圍：這台電腦、所有電腦，或某一台其他電腦（DeviceId）。</summary>
public sealed record TokenDeviceScope
{
    public enum Kind { ThisComputer, All, Device }

    public Kind Type { get; }
    public string? DeviceId { get; }

    private TokenDeviceScope(Kind type, string? deviceId = null)
    {
        Type = type;
        DeviceId = deviceId;
    }

    public static readonly TokenDeviceScope ThisComputer = new(Kind.ThisComputer);
    public static readonly TokenDeviceScope All = new(Kind.All);

    public static TokenDeviceScope Device(string id) => new(Kind.Device, id);

    /// <summary>存在設定裡的值（與 Mac 的 UserDefaults 相同）</summary>
    public string RawValue => Type switch
    {
        Kind.ThisComputer => "this",
        Kind.All => "all",
        _ => $"device:{DeviceId}",
    };

    public static TokenDeviceScope? Parse(string? raw) => raw switch
    {
        "this" => ThisComputer,
        "all" => All,
        // Swift 以字元數判斷「device:」後面還有東西
        { } r when r.StartsWith("device:", StringComparison.Ordinal) && r.Length > 7 => Device(r[7..]),
        _ => null,
    };
}

/// <summary>第二層的裝置清單與上傳狀態。</summary>
/// <param name="UploadRevoked">這台電腦的寫入密鑰失效，收集器已停止上傳（meta.upload_status = revoked）</param>
/// <param name="UploadCopied">history.sqlite3 是從別台電腦搬來的，收集器暫停上傳（meta.upload_status = copied，ADR-0014 D-2）</param>
public sealed record TokenDevices(IReadOnlyList<TokenDevice> Devices, bool UploadRevoked = false, bool UploadCopied = false)
{
    /// <summary>TokenDayRow.Device 裡代表這台電腦的值</summary>
    public const string Local = "";

    /// <summary>超過這麼久沒有上傳就在切換中標示「N 天前更新」</summary>
    public static readonly TimeSpan StaleAfter = TimeSpan.FromHours(48);

    public static readonly TokenDevices None = new([]);

    public IReadOnlyList<TokenDevice> Others => Devices.Where(d => !d.IsSelf).ToList();

    /// <summary>有其他電腦時才顯示裝置切換；沒有第二層時一律「這台電腦」（ADR-0011 第 4 節）</summary>
    public bool Enabled => Others.Count > 0;

    /// <summary>「所有電腦（N 台）」的 N：這台電腦＋其他電腦</summary>
    public int Count => Others.Count + 1;

    /// <summary>切換的選項：所有電腦、這台電腦、其他電腦（依中繼的清單順序）</summary>
    public IReadOnlyList<TokenDeviceScope> Scopes =>
        Enabled ? [TokenDeviceScope.All, TokenDeviceScope.ThisComputer, .. Others.Select(d => TokenDeviceScope.Device(d.Id))] : [TokenDeviceScope.ThisComputer];

    /// <summary>存下來的選擇已不存在（裝置被刪除）或第二層關閉時，退回預設：有第二層時「所有電腦」</summary>
    public TokenDeviceScope Resolve(TokenDeviceScope? scope)
    {
        if (!Enabled) return TokenDeviceScope.ThisComputer;
        return scope is not null && Scopes.Contains(scope) ? scope : TokenDeviceScope.All;
    }

    public string Title(TokenDeviceScope scope) => scope.Type switch
    {
        TokenDeviceScope.Kind.ThisComputer => "這台電腦",
        TokenDeviceScope.Kind.All => $"所有電腦（{Count} 台）",
        _ => Others.FirstOrDefault(d => d.Id == scope.DeviceId)?.Name ?? "其他電腦",
    };

    /// <summary>切換選單裡的一項：其他電腦超過 48 小時沒有上傳時加上「N 天前更新」</summary>
    public string MenuTitle(TokenDeviceScope scope, DateTimeOffset now)
    {
        if (scope.Type != TokenDeviceScope.Kind.Device || Others.FirstOrDefault(d => d.Id == scope.DeviceId) is not { } device
            || StaleNote(device, now) is not { } note)
        {
            return Title(scope);
        }
        return $"{device.Name}（{note}）";
    }

    /// <summary>撤銷了密鑰（保留資料）：「已撤銷」；超過 48 小時沒有上傳：「N 天前更新」；從未上傳：「尚未上傳」；其他為 null。</summary>
    public static string? StaleNote(TokenDevice device, DateTimeOffset now)
    {
        if (device.Revoked) return "已撤銷";
        if (device.LastUpload is not { } last) return "尚未上傳";
        var age = (now - last).TotalSeconds;
        return age > StaleAfter.TotalSeconds ? $"{(long)(age / 86400)} 天前更新" : null;
    }

    /// <summary>最後上傳時間（說明文字用）：剛剛／N 小時前／N 天前</summary>
    public static string UploadText(TokenDevice device, DateTimeOffset now)
    {
        if (device.LastUpload is not { } last) return "尚未上傳";
        var age = Math.Max((now - last).TotalSeconds, 0);
        if (age < 3600) return "剛剛上傳";
        if (age < 86400) return $"{(long)(age / 3600)} 小時前上傳";
        return $"{(long)(age / 86400)} 天前上傳";
    }

    public const string ThisComputerHelp =
        "只包含這台電腦上 Claude Code 與 Codex CLI 的對話紀錄（含它們的桌面 App 與編輯器外掛）。不包含 claude.ai 網頁、手機 App、其他電腦與雲端 session。額度 % 是整個帳號的數字。";

    private const string NotIncluded = "不包含 claude.ai 網頁、手機 App 與雲端 session。額度 % 是整個帳號的數字。";

    /// <summary>範圍標籤的滑鼠說明（ADR-0011 第 4 節）</summary>
    public string Help(TokenDeviceScope scope, DateTimeOffset now)
    {
        switch (scope.Type)
        {
            case TokenDeviceScope.Kind.ThisComputer:
                return ThisComputerHelp;
            case TokenDeviceScope.Kind.All:
                var me = Devices.FirstOrDefault(d => d.IsSelf) is { } self ? $"這台電腦（{UploadText(self, now)}）" : "這台電腦";
                var list = new[] { me }.Concat(Others.Select(d => $"{d.Name}（{UploadText(d, now)}）"));
                return $"包含已安裝收集器的電腦：{string.Join("、", list)}。其他電腦的數字是它們最後一次上傳的每日加總。" + NotIncluded;
            default:
                if (Others.FirstOrDefault(d => d.Id == scope.DeviceId) is not { } device) return ThisComputerHelp;
                return $"只包含「{device.Name}」上傳的每日 Token（{UploadText(device, now)}）。" + NotIncluded;
        }
    }

    /// <summary>空狀態的說明</summary>
    public string EmptyText(TokenDeviceScope scope) => scope.Type switch
    {
        TokenDeviceScope.Kind.ThisComputer => "這台電腦還沒有 Claude Code 或 Codex CLI 的紀錄",
        TokenDeviceScope.Kind.All => "還沒有任何電腦的 Claude Code 或 Codex CLI 紀錄",
        _ => $"「{Title(scope)}」還沒有上傳 Token 統計",
    };

    public bool Equals(TokenDevices? other) =>
        other is not null && Devices.SequenceEqual(other.Devices) && UploadRevoked == other.UploadRevoked && UploadCopied == other.UploadCopied;

    public override int GetHashCode() => HashCode.Combine(Devices.Count, UploadRevoked, UploadCopied);
}

public static class TokenStatsScoping
{
    /// <summary>
    /// 依裝置範圍篩選（TokenStatsData.scoped）。個人紀錄與每小時資料只有這台電腦有：所有電腦時個人紀錄改由每日資料計算、
    /// 每小時資料仍是這台電腦的；其他電腦沒有每小時資料，也沒有首次掃描的進度。DataFrom 只描述這台電腦的資料。
    /// </summary>
    public static TokenStatsData Scoped(this TokenStatsData data, TokenDeviceScope scope) => scope.Type switch
    {
        TokenDeviceScope.Kind.ThisComputer => data with { Days = data.Days.Where(d => d.Device == TokenDevices.Local).ToList() },
        TokenDeviceScope.Kind.All => data with
        {
            Records = new Dictionary<string, TokenRecord>(),
            RecordDays = new Dictionary<string, IReadOnlyDictionary<string, long>>(),
        },
        _ => data with
        {
            Days = data.Days.Where(d => d.Device == scope.DeviceId).ToList(),
            Records = new Dictionary<string, TokenRecord>(),
            RecordDays = new Dictionary<string, IReadOnlyDictionary<string, long>>(),
            Hours = [],
            FirstScanDone = true,
            FirstScanProgress = null,
            SkippedLines = 0,
            FormatSuspect = false,
            DataFrom = null,
        },
    };
}
