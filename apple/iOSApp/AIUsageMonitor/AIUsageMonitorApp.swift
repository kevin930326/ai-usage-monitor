import SwiftUI

@main
struct AIUsageMonitorApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
        }
    }
}
