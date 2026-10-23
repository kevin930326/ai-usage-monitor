import SwiftUI
import UsageKit

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
        // 打開 App 與回到前景時都更新（第一次 .active 也算，所以不必在 .task 再抓一次）。
        // 同時重排背景更新：先前排程失敗而中斷時，從這裡接回來
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            delegate.model.requestSettings()
            Task { await delegate.model.refresh() }
            delegate.scheduleBackgroundRefresh()
        }
    }
}

/// 背景重新整理：約每 30 分鐘抓一次中繼，存到 App Group 並重新整理複雜功能（FR-28）。
/// watchOS 依電量與使用情況決定實際時間，每小時最多約 4 次；錶面上有複雜功能時比較準時。
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static let backgroundInterval: TimeInterval = 30 * 60

    let model = WatchModel()
    private var scheduling: Task<Void, Never>?
    /// 每次 scheduleBackgroundRefresh 加一；較舊的要求失敗時不重試
    private var requestID = 0

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

    /// 同一時間只會有一個排程，重複呼叫會取代前一個。第一次直接送出排程要求（背景工作 `handle()`
    /// 在 `setTaskCompleted` 之前就已送出，整合審查 D-c）；失敗時才依 `BackgroundRefreshRetry`
    /// 延後重試（最多 3 次），否則背景更新會中斷到使用者再打開 App。
    func scheduleBackgroundRefresh() {
        scheduling?.cancel()
        scheduling = nil
        requestID += 1
        let id = requestID
        submitRequest { ok in
            // 已有較新的排程要求時不重試
            guard !ok, id == self.requestID else { return }
            self.retryScheduling()
        }
    }

    private func retryScheduling() {
        scheduling = Task {
            await BackgroundRefreshRetry.schedule(alreadyFailed: 1) {
                guard !Task.isCancelled else { return true }
                return await withCheckedContinuation { continuation in
                    self.submitRequest { continuation.resume(returning: $0) }
                }
            } sleep: { delay in
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 送出一次排程要求；結果在 main actor 上回報
    private func submitRequest(_ done: @escaping @MainActor (Bool) -> Void) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.backgroundInterval),
            userInfo: nil
        ) { error in
            if let error {
                print("背景重新整理排程失敗：\(error.localizedDescription)")
            }
            Task { @MainActor in done(error == nil) }
        }
    }
}
