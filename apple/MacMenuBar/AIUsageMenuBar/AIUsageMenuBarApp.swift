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
            #if DEBUG
            DebugTools.runIfRequested()
            #endif
        }
    }
}
