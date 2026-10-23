import SwiftUI

@main
struct AIUsageMonitorApp: App {
    @State private var model = UsageModel()

    init() {
        WatchSettingsSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .task {
                    #if DEBUG
                    IslandRender.runIfRequested()
                    #endif
                    // scripts/reinstall-ios.sh 重新安裝後以這個參數開啟 App：重新安裝會結束鎖定畫面的卡片，
                    // 在這裡開回來（開卡需要 App 在前景，所以不能在安裝時做）
                    if CommandLine.arguments.contains(UsageModel.startActivityArgument),
                       model.isConfigured, !LiveActivityController.isRunning {
                        await model.startLiveActivity()
                    }
                }
        }
    }
}
