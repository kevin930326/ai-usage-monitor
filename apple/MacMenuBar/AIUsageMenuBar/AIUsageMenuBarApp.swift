import SwiftUI

@main
struct AIUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore.shared
    @State private var settings = PanelSettings.shared
    @State private var history = HistoryStore.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
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
        }
        .defaultSize(width: 860, height: 700)
        .windowResizability(.contentMinSize)

        // 設定視窗：關閉後釋放（ADR-0008 第 5 節）
        Settings {
            SettingsView()
                .environment(store)
                .environment(settings)
                .environment(history)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            UsageStore.shared.start()
            // 第四階段（FR-19、FR-47）：通知、右鍵選單、全域快捷鍵
            QuotaNotifier.shared.start()
            AppActions.installRightClickMenu()
            GlobalHotKey.shared.apply(PanelSettings.shared.hotKey)
            #if DEBUG
            DebugTools.runIfRequested()
            #endif
        }
    }
}
