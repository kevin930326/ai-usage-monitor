using System;
using System.IO;
using System.Text;
using System.Windows.Threading;
using AIUsageMonitor.Core;

namespace AIUsageMonitor.Windows;

/// <summary>收集器與 App 共用的資料夾（收集器的 paths.py）：AI_USAGE_MONITOR_HOME 有值用它，否則 %LOCALAPPDATA%\AIUsageMonitor。</summary>
internal static class DataPaths
{
    public static string Home =>
        Environment.GetEnvironmentVariable("AI_USAGE_MONITOR_HOME") is { Length: > 0 } custom
            ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIUsageMonitor");

    public static string Usage => Path.Combine(Home, "usage.json");
    public static string Settings => Path.Combine(Home, "windows-app.json");
    public static string Log => Path.Combine(Home, "logs", "windows-app.log");
}

/// <summary>
/// 讀 usage.json（Mac 的 UsageStore，ADR-0015 第 2 節）：監看資料夾（收集器先寫暫存檔再改名）、300 ms 去抖動後重讀，
/// 內容沒變就不通知。監看出錯或資料夾還不存在時，由 App 每分鐘的計時器呼叫 <see cref="Poll"/> 重讀並重建監看。閒置時沒有輪詢。
/// </summary>
internal sealed class UsageStore : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly DispatcherTimer debounce;
    private FileSystemWatcher? watcher;
    private string? lastText;
    private string? lastError;
    private bool loaded;
    private bool retry;

    public UsageSnapshot? Snapshot { get; private set; }
    /// <summary>讀不到或解析失敗時的說明（沒有檔案時為 null，Snapshot 也是 null）</summary>
    public string? Error { get; private set; }

    public event Action? Changed;

    public UsageStore(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        debounce = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(300) };
        debounce.Tick += (_, _) =>
        {
            debounce.Stop();
            Reload();
        };
    }

    public void Start()
    {
        EnsureWatcher();
        Reload();
    }

    /// <summary>每分鐘：監看不在時重建並重讀；上次讀取遇到暫時的 I/O 錯誤時補讀（監看在、讀取正常時不讀檔）</summary>
    public void Poll()
    {
        if (watcher is null)
        {
            EnsureWatcher();
            Reload();
        }
        else if (retry)
        {
            Reload();
        }
    }

    /// <summary>「立即更新」按下時也重讀一次</summary>
    public void Reload()
    {
        string? text = null;
        string? error = null;
        retry = false;
        try
        {
            text = ReadShared(DataPaths.Usage);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            // 還沒有資料：收集器沒有以 -WithQuota 安裝或還沒跑第一輪
        }
        catch (UnauthorizedAccessException)
        {
            error = "沒有權限讀取 usage.json";
        }
        catch (IOException e)
        {
            // 收集器正在改名或檔案被鎖住：下一次變更或每分鐘的計時器（Poll）再讀
            AppLog.Write($"read usage.json: {e.GetType().Name}");
            retry = true;
            return;
        }
        if (loaded && text == lastText && error == lastError) return;
        loaded = true;
        lastText = text;
        lastError = error;
        Snapshot = null;
        Error = error;
        if (text is not null)
        {
            try
            {
                Snapshot = UsageDecoder.Decode(text);
            }
            catch (UsageDecodingException e)
            {
                Error = e.Message;
            }
        }
        Changed?.Invoke();
    }

    private static string ReadShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private void EnsureWatcher()
    {
        if (watcher is not null || !Directory.Exists(DataPaths.Home)) return;
        try
        {
            var w = new FileSystemWatcher(DataPaths.Home, "usage.json")
            {
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                IncludeSubdirectories = false,
            };
            FileSystemEventHandler onChange = (_, _) => dispatcher.BeginInvoke(Restart);
            w.Changed += onChange;
            w.Created += onChange;
            w.Deleted += onChange;
            w.Renamed += (_, _) => dispatcher.BeginInvoke(Restart);
            w.Error += (_, e) => dispatcher.BeginInvoke(() =>
            {
                AppLog.Write($"watcher error: {e.GetException().GetType().Name}");
                DropWatcher();
            });
            w.EnableRaisingEvents = true;
            watcher = w;
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException)
        {
            AppLog.Write($"watcher: {e.GetType().Name}");
        }
    }

    private void Restart()
    {
        debounce.Stop();
        debounce.Start();
    }

    private void DropWatcher()
    {
        watcher?.Dispose();
        watcher = null;
    }

    public void Dispose()
    {
        debounce.Stop();
        DropWatcher();
    }
}

/// <summary>App 自己的日誌（logs\windows-app.log，超過 256 KB 時換一份）。不寫密鑰、不寫 usage.json 的內容。</summary>
internal static class AppLog
{
    private const long MaxBytes = 256 * 1024;
    // 事故頁在背景執行緒打開，失敗時也會寫日誌
    private static readonly object Gate = new();

    public static void Write(string message)
    {
        lock (Gate)
        try
        {
            var path = DataPaths.Log;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var info = new FileInfo(path);
            if (info.Exists && info.Length > MaxBytes) File.Move(path, path + ".1", overwrite: true);
            File.AppendAllText(path, $"{DateTimeOffset.Now:yyyy-MM-ddTHH:mm:sszzz} {message}{Environment.NewLine}", Encoding.UTF8);
        }
        catch (Exception)
        {
            // 日誌寫不進去不影響 App
        }
    }
}

/// <summary>windows-app.json 的讀寫：先寫暫存檔再改名，寫不進去時只記日誌。</summary>
internal static class SettingsFile
{
    public static AppSettings Load()
    {
        try
        {
            return AppSettings.Parse(File.Exists(DataPaths.Settings) ? File.ReadAllText(DataPaths.Settings, Encoding.UTF8) : null);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"settings load: {e.GetType().Name}");
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            Directory.CreateDirectory(DataPaths.Home);
            var temp = DataPaths.Settings + ".tmp";
            File.WriteAllText(temp, settings.Serialize(), new UTF8Encoding(false));
            File.Move(temp, DataPaths.Settings, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"settings save: {e.GetType().Name}");
        }
    }
}
