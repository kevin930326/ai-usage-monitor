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
        }
    }
}
