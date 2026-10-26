using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace AIUsageMonitor.Core;

/// <summary>
/// 系統內建的 SQLite（不帶套件，ADR-0015 第 4 節）：Windows 10 以上的 winsqlite3.dll、macOS 的 libsqlite3.dylib、Linux 的 libsqlite3.so.0。
/// 只宣告讀取需要的函式；HistoryReader 以外不要直接用。
/// </summary>
internal static class Sqlite
{
    public const int Ok = 0;
    public const int Row = 100;
    public const int Done = 101;
    public const int Null = 5;
    public const int OpenReadWrite = 0x00000002;
    public const int OpenNoMutex = 0x00008000;
    /// <summary>SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE</summary>
    public const int ConfigNoCheckpointOnClose = 1006;

    private const string Library = "sqlite3";
    /// <summary>SQLITE_TRANSIENT：SQLite 自己複製綁定的字串</summary>
    private static readonly IntPtr Transient = new(-1);

    static Sqlite()
    {
        NativeLibrary.SetDllImportResolver(typeof(Sqlite).Assembly, Resolve);
    }

    private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != Library) return IntPtr.Zero;
        string[] candidates = OperatingSystem.IsWindows() ? ["winsqlite3"]
            : OperatingSystem.IsMacOS() ? ["/usr/lib/libsqlite3.dylib", "libsqlite3.dylib"]
            : ["libsqlite3.so.0", "libsqlite3.so"];
        foreach (var candidate in candidates)
        {
            // Windows 只從 System32 載入，不讀 App 資料夾或目前資料夾裡同名的 DLL
            var searchPath = OperatingSystem.IsWindows() ? DllImportSearchPath.System32 : (DllImportSearchPath?)null;
            if (NativeLibrary.TryLoad(candidate, assembly, searchPath, out var handle)) return handle;
        }
        return IntPtr.Zero;
    }

    /// <summary>確保 DllImport 解析器已經設定（靜態建構子在第一次用到這個類別時執行）。</summary>
    public static void EnsureLoaded() { }

    [DllImport(Library, EntryPoint = "sqlite3_open_v2")]
    private static extern int OpenV2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);

    public static int Open(string path, int flags, out IntPtr db) => OpenV2(Utf8(path), out db, flags, IntPtr.Zero);

    [DllImport(Library, EntryPoint = "sqlite3_close_v2")]
    public static extern int Close(IntPtr db);

    [DllImport(Library, EntryPoint = "sqlite3_busy_timeout")]
    public static extern int BusyTimeout(IntPtr db, int ms);

    // 可變參數的函式：Windows（x64、ARM64）的可變參數與一般參數傳法相同，只在 Windows 呼叫（macOS ARM64 不同）
    [DllImport(Library, EntryPoint = "sqlite3_db_config")]
    private static extern int DbConfigInt(IntPtr db, int op, int value, IntPtr result);

    public static int DbConfig(IntPtr db, int op, int value) =>
        OperatingSystem.IsWindows() ? DbConfigInt(db, op, value, IntPtr.Zero) : Ok;

    [DllImport(Library, EntryPoint = "sqlite3_exec")]
    private static extern int ExecRaw(IntPtr db, byte[] sql, IntPtr callback, IntPtr arg, IntPtr errmsg);

    public static int Exec(IntPtr db, string sql) => ExecRaw(db, Utf8(sql), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

    [DllImport(Library, EntryPoint = "sqlite3_prepare_v2")]
    private static extern int PrepareRaw(IntPtr db, byte[] sql, int length, out IntPtr stmt, IntPtr tail);

    public static int Prepare(IntPtr db, string sql, out IntPtr stmt) => PrepareRaw(db, Utf8(sql), -1, out stmt, IntPtr.Zero);

    [DllImport(Library, EntryPoint = "sqlite3_bind_int64")]
    public static extern int BindInt64(IntPtr stmt, int index, long value);

    [DllImport(Library, EntryPoint = "sqlite3_bind_text")]
    private static extern int BindTextRaw(IntPtr stmt, int index, byte[] value, int length, IntPtr destructor);

    public static int BindText(IntPtr stmt, int index, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        return BindTextRaw(stmt, index, bytes, bytes.Length, Transient);
    }

    [DllImport(Library, EntryPoint = "sqlite3_step")]
    public static extern int Step(IntPtr stmt);

    [DllImport(Library, EntryPoint = "sqlite3_finalize")]
    public static extern int Finalize(IntPtr stmt);

    [DllImport(Library, EntryPoint = "sqlite3_column_type")]
    public static extern int ColumnType(IntPtr stmt, int column);

    [DllImport(Library, EntryPoint = "sqlite3_column_int64")]
    public static extern long ColumnInt64(IntPtr stmt, int column);

    [DllImport(Library, EntryPoint = "sqlite3_column_double")]
    public static extern double ColumnDouble(IntPtr stmt, int column);

    [DllImport(Library, EntryPoint = "sqlite3_column_text")]
    private static extern IntPtr ColumnTextRaw(IntPtr stmt, int column);

    public static string? ColumnText(IntPtr stmt, int column)
    {
        var p = ColumnTextRaw(stmt, column);
        return p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
    }

    /// <summary>以 NUL 結尾的 UTF-8</summary>
    private static byte[] Utf8(string s)
    {
        var bytes = new byte[Encoding.UTF8.GetByteCount(s) + 1];
        Encoding.UTF8.GetBytes(s, 0, s.Length, bytes, 0);
        return bytes;
    }
}
