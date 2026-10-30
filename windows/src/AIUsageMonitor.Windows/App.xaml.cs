using System;
using System.Linq;
using System.Windows;
using System.Windows.Threading;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 進入點。命令列：
/// - （沒有參數）啟動；已在執行時請它打開面板
/// - <c>--show-panel</c>／<c>--hide-panel</c>／<c>--quit</c>：交給執行中的 App（效能量測、安裝腳本）
/// - <c>--isolated</c>：不改開機自動啟動、不觸發收集器（效能量測與測試，和 AI_USAGE_MONITOR_HOME 的暫存資料夾一起用）
/// - Debug 版另有截圖與示範資料的參數（DebugTools），Release 版沒有
/// </summary>
public partial class App : Application
{
    private SingleInstance? instance;
    private AppHost? host;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var args = e.Args;
        DispatcherUnhandledException += OnUnhandled;
        WheelGuard.Install();
#if DEBUG
        if (DebugTools.TryRun(args, out var code))
        {
            Shutdown(code);
            return;
        }
#endif
        if (args.Contains("--isolated")) AppMode.Isolated = true;
        instance = new SingleInstance();
        var command = args.Contains("--quit") ? "quit" : args.Contains("--hide-panel") ? "hide" : "show";
        if (!instance.IsFirst)
        {
            instance.Send(command);
            instance.Dispose();
            instance = null;
            Shutdown(0);
            return;
        }
        if (command == "quit")
        {
            Shutdown(0);
            return;
        }
        NativeMethods.SetCurrentProcessExplicitAppUserModelID(SingleInstance.Id);
        host = new AppHost(Dispatcher);
        host.Start();
        instance.Listen(Dispatcher, host.ShowPanel, host.HidePanel, host.Quit, host.AgentEvent);
        if (args.Contains("--show-panel")) host.ShowPanel();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        host?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }

    private static void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // 只記類型與位置（不寫資料內容）；畫面的小錯誤不讓整個 App 結束
        AppLog.Write($"unhandled {e.Exception.GetType().Name}: {e.Exception.TargetSite?.DeclaringType?.Name}.{e.Exception.TargetSite?.Name}");
        e.Handled = true;
    }
}
