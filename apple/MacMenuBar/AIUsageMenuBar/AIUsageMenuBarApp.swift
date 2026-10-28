import SwiftUI

@main
struct AIUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore.shared
    @State private var settings = PanelSettings.shared
    @State private var history = HistoryStore.shared
    @State private var collector = CollectorService.shared

    init() {
        // scripts/install.sh --uninstall：解除內建收集器的註冊後立即結束，不顯示選單列
        CollectorService.handleCommandLine()
    }

    var body: some Scene {
        // 選單列圖示可以關（ADR-0008 第 9 節）；使用者用 ⌘ 拖走圖示時系統也會改這個值。
        // 設成不顯示時，啟動後先放出來到標籤取得 openWindow／openSettings 為止（Fable F-01）
        MenuBarExtra(isInserted: Binding(get: { settings.menuBarIconShown || !settings.windowActionsReady }, set: { shown in
            guard settings.windowActionsReady else { return }
            settings.menuBarIconShown = shown || !settings.canHideMenuBarIcon
        })) {
            PanelView()
                .followsAppearanceSetting()
                .environment(store)
                .environment(settings)
                .environment(history)
        } label: {
            MenuBarLabel(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)

        // 完整統計視窗：打開時才讀資料庫，關閉時釋放（FR-44、ADR-0009 第 7 節）
        Window("完整統計", id: StatsWindowView.windowID) {
            StatsWindowView(historyStore: history)
                .followsAppearanceSetting()
                .environment(settings)
        }
        .defaultSize(width: 860, height: 700)
        .windowResizability(.contentMinSize)

        // 首次設定精靈（FR-54）：第一次打開且還沒有資料時自動顯示，之後從設定重新打開
        Window("設定精靈", id: SetupWizardView.windowID) {
            SetupWizardView(model: .shared)
                .followsAppearanceSetting()
                .environment(collector)
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // 設定視窗：關閉後釋放（ADR-0008 第 5 節）
        Settings {
            SettingsView()
                .followsAppearanceSetting()
                .environment(collector)
                .environment(store)
                .environment(settings)
                .environment(history)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 第四階段（FR-19、FR-47）：通知、右鍵選單、全域快捷鍵。通知要先開始：
            // 第一次打開 App 的權限詢問有結果之前不判斷事件
            QuotaNotifier.shared.start()
            UsageStore.shared.start()
            // App 內建的收集器（ADR-0013）：首次打開自動註冊、搬家後重新註冊；偵測到舊安裝時不註冊
            Task { await CollectorService.shared.start() }
            AppActions.installRightClickMenu()
            // 截圖與示範模式不註冊（不搶正式 App 的快捷鍵，Fable F-20）
            #if DEBUG
            let registersHotKey = !DebugTools.isDemo
            #else
            let registersHotKey = true
            #endif
            if registersHotKey { GlobalHotKey.shared.apply(PanelSettings.shared.hotKey) }
            // 瀏海面板（ADR-0016）：設定預設開啟
            NotchPanelController.shared.apply()
            // 瀏海其實沒顯示（設定檔讀不到）又關了選單列圖示：把圖示放回來，不會兩個入口都沒有（Fable F-12）
            if !NotchPanelController.shared.isShown, !PanelSettings.shared.menuBarIconShown {
                PanelSettings.shared.menuBarIconShown = true
            }
            // hook 的 socket（ADR-0017）：先開始聽，AI 的事件才不會丟
            AgentMonitor.shared.start()
            // App 被移動或 hook 缺事件：設定裡顯示「需要修好」
            AgentHookInstaller.shared.refresh()
            #if DEBUG
            DebugTools.runIfRequested()
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 移除 socket 檔：hook 看到沒有 socket 就立刻結束，不必等連線逾時
        MainActor.assumeIsolated { AgentMonitor.shared.stop() }
    }
}
