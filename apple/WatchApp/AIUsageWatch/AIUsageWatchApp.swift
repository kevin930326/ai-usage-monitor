import SwiftUI

@main
struct AIUsageWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            UsageListView()
                .environment(delegate.model)
                .task {
                    delegate.model.activateConnectivity()
                    #if DEBUG
                    await delegate.model.refresh()
                    DebugRender.runIfRequested(snapshot: delegate.model.snapshot)
                    #endif
                }
        }
        // 打開 App 與回到前景時都更新（第一次 .active 也算，所以不必在 .task 再抓一次）
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            delegate.model.requestSettings()
            Task { await delegate.model.refresh() }
        }
    }
}

/// 背景重新整理：約每 30 分鐘抓一次中繼，存到 App Group 並重新整理複雜功能（FR-28）。
/// watchOS 依電量與使用情況決定實際時間，每小時最多約 4 次；錶面上有複雜功能時比較準時。
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static let backgroundInterval: TimeInterval = 30 * 60

    let model = WatchModel()

    func applicationDidFinishLaunching() {
        scheduleBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            Task {
                // refresh() 會存到 App Group 並呼叫 reloadAllTimelines
                await model.refresh()
                scheduleBackgroundRefresh()
                refresh.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// 同一時間只會有一個排程，重複呼叫會取代前一個
    private func scheduleBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.backgroundInterval),
            userInfo: nil
        ) { error in
            if let error {
                print("背景重新整理排程失敗：\(error.localizedDescription)")
            }
        }
    }
}
