namespace AIUsageMonitor.Core;

/// <summary>
/// 唯讀開啟收集器寫的 history.sqlite3（照 Mac 的 HistoryStore，FR-37、ADR-0009 第 7 節、ADR-0015 第 2 節）。
///
/// - App 只讀：不建立檔案、不建表、不執行 migration；連線設 query_only。
/// - 每次讀取開一個連線、讀完立刻關閉：Windows 上開著的檔案不能改名或刪除（SQLite 開檔不帶 FILE_SHARE_DELETE），
///   收集器的整理（VACUUM、損毀時改名保留）不能被 App 擋住；短暫的連線也不會讓收集器的 checkpoint 一直等讀取者。
/// - WAL 模式的讀取不擋收集器寫入，也不被寫入擋住（讀到提交前的狀態）；收集器正在 checkpoint 或改日誌模式時最多等 1 秒。
/// - 不用 SQLITE_OPEN_READONLY：WAL 模式的唯讀連線在 -shm 不存在時開不了（同 Mac）。改以讀寫模式開啟（不帶 CREATE）並設
///   query_only；Windows 另外設 NO_CKPT_ON_CLOSE，關閉時不做 checkpoint（不改主檔）。
/// - 錯誤只記錄類別，不帶 SQLite 的訊息（可能含路徑）。
/// </summary>
public sealed class HistoryReader(string path)
{
    /// <summary>App 支援的資料庫版本（meta.schema_version）；收集器的 history.SCHEMA_VERSION 改了這裡要一起改</summary>
    public const int SupportedSchema = 3;

    /// <summary>面板需要的範圍：本週走勢最長 7 天、額度消耗 7 天、近期速度 24 小時，多留一天給跨日的差值</summary>
    public static readonly TimeSpan Lookback = TimeSpan.FromDays(8);

    /// <summary>每日 Token 讀取的範圍：一年的熱力圖也用這個範圍</summary>
    public const int TokenLookbackDays = 371;

    public const int DefaultRetentionDays = 365;

    /// <summary>讀取時最多等收集器多久（WAL 模式下讀取通常不會被寫入擋住）</summary>
    public const int BusyTimeoutMs = 1000;

    public enum Status
    {
        /// <summary>檔案不存在：收集器還沒寫入（剛安裝、或收集器沒有歷史功能）</summary>
        Missing,
        Ready,
        /// <summary>檔案版本比 App 支援的舊（收集器尚未更新）：請重新執行收集器的安裝腳本</summary>
        OlderSchema,
        /// <summary>檔案版本較新：照樣讀取，請更新 App</summary>
        NewerSchema,
        /// <summary>讀不了（損毀、權限、被鎖住超過 1 秒）</summary>
        Failed,
    }

    /// <param name="Stage">失敗在哪一步（open、schema、query），寫日誌用；成功時為 null</param>
    public sealed record Result(Status Status, int? SchemaVersion, QuotaHistory History, TokenStatsData Tokens, string? Stage = null)
    {
        public bool CanRead => Status is Status.Ready or Status.NewerSchema;
    }

    public string Path { get; } = path;

    /// <summary>額度歷史讀完、Token 統計開始讀之前呼叫（仍在同一個讀取交易內）。只給測試在查詢之間讓收集器提交</summary>
    public Action? BetweenQueries { get; init; }

    /// <summary>
    /// 讀取面板需要的資料：最近 8 天的額度歷史與收集紀錄、最近一年的每日 Token（含其他電腦）、個人紀錄、裝置清單。
    /// <paramref name="hourly"/> 為真時另外讀每小時 Token（完整統計視窗）。<paramref name="zone"/> 決定每日資料的起始日期。
    /// </summary>
    public Result Read(DateTimeOffset now, TimeZoneInfo zone, bool hourly = false)
    {
        if (!File.Exists(Path)) return new Result(Status.Missing, null, QuotaHistory.Empty, TokenStatsData.Empty);
        Sqlite.EnsureLoaded();
        IntPtr db;
        try
        {
            if (Sqlite.Open(Path, Sqlite.OpenReadWrite | Sqlite.OpenNoMutex, out db) != Sqlite.Ok)
            {
                Sqlite.Close(db);
                return Failed("open");
            }
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            return Failed("library");
        }
        try
        {
            Sqlite.DbConfig(db, Sqlite.ConfigNoCheckpointOnClose, 1);
            Sqlite.BusyTimeout(db, BusyTimeoutMs);
            if (Sqlite.Exec(db, "PRAGMA query_only = ON") != Sqlite.Ok) return Failed("open");
            // 所有查詢在同一個讀取交易內：WAL 的快照從第一個 SELECT 開始，收集器在查詢之間提交時，
            // 這次讀到的仍全是提交前的資料（不會每日 Token 是舊的、個人紀錄是新的）。讀取交易不擋寫入；
            // 交易由 Close 結束（沒有寫入，等同 ROLLBACK）
            if (Sqlite.Exec(db, "BEGIN") != Sqlite.Ok) return Failed("open");
            var version = SchemaVersion(db);
            if (version is not { } v) return Failed("schema");
            if (v < SupportedSchema) return new Result(Status.OlderSchema, v, QuotaHistory.Empty, TokenStatsData.Empty);
            var since = (now - Lookback).ToUnixTimeSeconds();
            if (Samples(db, since) is not { } samples || Runs(db, since) is not { } runs) return Failed("query");
            BetweenQueries?.Invoke();
            // Token 統計讀不了（例如收集器還在建立表）時不影響額度歷史
            var tokens = TokenStats(db, now, zone, hourly) ?? TokenStatsData.Empty;
            return new Result(v > SupportedSchema ? Status.NewerSchema : Status.Ready, v, new QuotaHistory(samples, runs), tokens);
        }
        finally
        {
            Sqlite.Close(db);
        }
    }

    private static Result Failed(string stage) => new(Status.Failed, null, QuotaHistory.Empty, TokenStatsData.Empty, stage);

    /// <summary>
    /// 檔案是否可能有新資料：主檔與 -wal 的大小與修改時間（App 每分鐘比對，變了才重新讀）。
    /// 不開連線，所以不能用 PRAGMA data_version（它只在同一個連線裡比較才有意義）。
    /// </summary>
    public string ChangeStamp()
    {
        static string Stamp(string p)
        {
            var info = new FileInfo(p);
            return info.Exists ? $"{info.Length}:{info.LastWriteTimeUtc.Ticks}" : "-";
        }
        return $"{Stamp(Path)}|{Stamp(Path + "-wal")}";
    }

    // MARK: 查詢

    private abstract record Value
    {
        public sealed record Int(long V) : Value;
        public sealed record Text(string V) : Value;
    }

    /// <summary>查詢每一列；make 回傳 null 的列略過（欄位是 NULL），查詢失敗時整個回傳 null</summary>
    private static List<T>? Rows<T>(IntPtr db, string sql, Value[] values, Func<IntPtr, T?> make) where T : class
    {
        if (Sqlite.Prepare(db, sql, out var stmt) != Sqlite.Ok)
        {
            Sqlite.Finalize(stmt);
            return null;
        }
        try
        {
            for (var i = 0; i < values.Length; i++)
            {
                var rc = values[i] switch
                {
                    Value.Int n => Sqlite.BindInt64(stmt, i + 1, n.V),
                    Value.Text t => Sqlite.BindText(stmt, i + 1, t.V),
                    _ => throw new InvalidOperationException(),
                };
                if (rc != Sqlite.Ok) return null;
            }
            var result = new List<T>();
            while (true)
            {
                var rc = Sqlite.Step(stmt);
                if (rc == Sqlite.Done) return result;
                if (rc != Sqlite.Row) return null;
                if (make(stmt) is { } item) result.Add(item);
            }
        }
        finally
        {
            Sqlite.Finalize(stmt);
        }
    }

    private sealed record Box(long Value);

    private sealed record RecordRow(string Key, TokenRecord Record);

    private sealed record RecordDayRow(string Day, string Provider, long Tokens);

    private static long? Scalar(IntPtr db, string sql, params Value[] values) =>
        Rows(db, sql, values, s => Sqlite.ColumnType(s, 0) == Sqlite.Null ? null : new Box(Sqlite.ColumnInt64(s, 0))) is { Count: > 0 } r
            ? r[0].Value
            : null;

    private static string? Meta(IntPtr db, string key) =>
        Rows(db, "SELECT value FROM meta WHERE key = ?", [new Value.Text(key)], s => Sqlite.ColumnText(s, 0)) is { Count: > 0 } r ? r[0] : null;

    private static bool TableExists(IntPtr db, string name) =>
        Scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", new Value.Text(name)) == 1;

    /// <summary>meta.schema_version；沒有 meta 表是 0（收集器還沒建立任何東西）；讀不了為 null</summary>
    internal static int? SchemaVersion(IntPtr db)
    {
        if (Scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") is not { } count) return null;
        if (count != 1) return 0;
        return int.TryParse(Meta(db, "schema_version"), out var v) ? v : 0;
    }

    private static DateTimeOffset Epoch(long seconds) => DateTimeOffset.FromUnixTimeSeconds(seconds);

    private static List<QuotaSample>? Samples(IntPtr db, long since) =>
        Rows(db, "SELECT ts, provider, window_id, used_pct, resets_at FROM quota_samples WHERE ts >= ? ORDER BY ts", [new Value.Int(since)], s =>
        {
            if (Sqlite.ColumnText(s, 1) is not { } provider || Sqlite.ColumnText(s, 2) is not { } window) return null;
            DateTimeOffset? resets = Sqlite.ColumnType(s, 4) == Sqlite.Null ? null : Epoch(Sqlite.ColumnInt64(s, 4));
            return new QuotaSample(Epoch(Sqlite.ColumnInt64(s, 0)), provider, window, Sqlite.ColumnDouble(s, 3), resets);
        });

    private static List<CollectorRun>? Runs(IntPtr db, long since) =>
        Rows(db, "SELECT ts, ok, runs FROM collector_runs WHERE ts >= ? ORDER BY ts", [new Value.Int(since)], s =>
            new CollectorRun(Epoch(Sqlite.ColumnInt64(s, 0)), (int)Sqlite.ColumnInt64(s, 1), (int)Sqlite.ColumnInt64(s, 2)));

    private const string TokenColumns = "input_tokens, cache_write_tokens, cache_read_tokens, output_tokens, reasoning_tokens";

    private static TokenCounts Counts(IntPtr s, int column) =>
        new(Sqlite.ColumnInt64(s, column), Sqlite.ColumnInt64(s, column + 1), Sqlite.ColumnInt64(s, column + 2),
            Sqlite.ColumnInt64(s, column + 3), Sqlite.ColumnInt64(s, column + 4));

    private static TokenStatsData? TokenStats(IntPtr db, DateTimeOffset now, TimeZoneInfo zone, bool hourly)
    {
        if (!TableExists(db, "daily_tokens") || !TableExists(db, "records") || !TableExists(db, "record_days")) return null;
        var device = Meta(db, "device_id") ?? "";
        var since = LocalCalendar.Key(LocalCalendar.Date(now.AddDays(-TokenLookbackDays), zone));
        var days = Rows(db, $"""
            SELECT device_id, day, provider, model, {TokenColumns}, task_count, task_seconds, longest_task_seconds
            FROM daily_tokens WHERE day >= ? ORDER BY day
            """, [new Value.Text(since)], s =>
        {
            if (Sqlite.ColumnText(s, 0) is not { } id || Sqlite.ColumnText(s, 1) is not { } day
                || Sqlite.ColumnText(s, 2) is not { } provider || Sqlite.ColumnText(s, 3) is not { } model)
            {
                return null;
            }
            return new TokenDayRow(day, provider, model, Counts(s, 4), (int)Sqlite.ColumnInt64(s, 9), (int)Sqlite.ColumnInt64(s, 10),
                                   (int)Sqlite.ColumnInt64(s, 11), id == device ? TokenDevices.Local : id);
        });
        var records = Rows(db, "SELECT key, value, day FROM records", [], s =>
            Sqlite.ColumnText(s, 0) is { } key ? new RecordRow(key, new TokenRecord(Sqlite.ColumnInt64(s, 1), Sqlite.ColumnText(s, 2))) : null);
        // 不設下界：目前的連續天數可能比圖表範圍長（每天最多兩列）
        var recordDays = Rows(db, "SELECT day, provider, tokens FROM record_days", [], s =>
            Sqlite.ColumnText(s, 0) is { } day && Sqlite.ColumnText(s, 1) is { } provider ? new RecordDayRow(day, provider, Sqlite.ColumnInt64(s, 2)) : null);
        List<TokenHourRow>? hours = [];
        if (hourly && TableExists(db, "hourly_tokens"))
        {
            hours = Rows(db, $"SELECT day, hour, provider, model, {TokenColumns} FROM hourly_tokens WHERE device_id = ?", [new Value.Text(device)], s =>
                Sqlite.ColumnText(s, 0) is { } day && Sqlite.ColumnText(s, 2) is { } provider && Sqlite.ColumnText(s, 3) is { } model
                    ? new TokenHourRow(day, (int)Sqlite.ColumnInt64(s, 1), provider, model, Counts(s, 4))
                    : null);
        }
        if (days is null || records is null || recordDays is null || hours is null) return null;
        var recordMap = new Dictionary<string, TokenRecord>();
        foreach (var r in records) recordMap.TryAdd(r.Key, r.Record);
        var dayMap = new Dictionary<string, Dictionary<string, long>>();
        foreach (var r in recordDays)
        {
            if (!dayMap.TryGetValue(r.Day, out var map)) dayMap[r.Day] = map = [];
            map[r.Provider] = r.Tokens;
        }
        var skipped = new[] { "token_bad_lines", "token_long_lines" }.Select(k => int.TryParse(Meta(db, k), out var n) ? n : 0).Sum();
        var retention = int.TryParse(Meta(db, "retention_days"), out var rd) && rd >= 0 ? rd : DefaultRetentionDays;
        return new TokenStatsData
        {
            Days = days,
            Hours = hours,
            Records = recordMap,
            RecordDays = dayMap.ToDictionary(p => p.Key, p => (IReadOnlyDictionary<string, long>)p.Value),
            FirstScanDone = Meta(db, "first_scan_done") == "1",
            FirstScanProgress = int.TryParse(Meta(db, "first_scan_progress"), out var progress) ? Math.Clamp(progress, 0, 100) : null,
            SkippedLines = skipped,
            RetentionDays = retention,
            DataFrom = Meta(db, "token_days_from"),
            FormatSuspect = Meta(db, "token_format_suspect") == "1",
            Devices = Devices(db),
        };
    }

    /// <summary>中繼的裝置清單（收集器下載時整批取代）與這台電腦的上傳狀態；沒有第二層時是空的</summary>
    private static TokenDevices Devices(IntPtr db)
    {
        var upload = Meta(db, "upload_status");
        bool revoked = upload == "revoked", copied = upload == "copied";
        if (!TableExists(db, "devices")) return new TokenDevices([], revoked, copied);
        var list = Rows(db, "SELECT device_id, name, last_upload_at, revoked, is_self FROM devices ORDER BY rowid", [], s =>
        {
            if (Sqlite.ColumnText(s, 0) is not { } id || Sqlite.ColumnText(s, 1) is not { } name) return null;
            DateTimeOffset? last = Sqlite.ColumnType(s, 2) == Sqlite.Null ? null : Epoch(Sqlite.ColumnInt64(s, 2));
            return new TokenDevice(id, name, last, Sqlite.ColumnInt64(s, 3) != 0, Sqlite.ColumnInt64(s, 4) != 0);
        });
        return new TokenDevices(list ?? [], revoked, copied);
    }
}
