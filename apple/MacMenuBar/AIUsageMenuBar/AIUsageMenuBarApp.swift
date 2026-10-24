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
        MenuBarExtra {
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
            GlobalHotKey.shared.apply(PanelSettings.shared.hotKey)
            #if DEBUG
            DebugTools.runIfRequested()
            #endif
        }
    }
}
