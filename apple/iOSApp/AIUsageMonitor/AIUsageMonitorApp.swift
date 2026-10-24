import SwiftUI
import UsageKit

@main
struct AIUsageMonitorApp: App {
    @State private var model = UsageModel()
    /// 外觀（FR-52）：只存在 App 自己的 UserDefaults，小工具與 Live Activity 不讀
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue

    init() {
        WatchSettingsSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .windowAppearance(AppearanceChoice(stored: appearance))
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
