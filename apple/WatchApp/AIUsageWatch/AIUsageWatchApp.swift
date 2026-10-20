import SwiftUI

@main
struct AIUsageWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            UsageListView()
                .environment(model)
                .task {
                    model.activateConnectivity()
                    await model.refresh()
                    #if DEBUG
                    DebugRender.runIfRequested(snapshot: model.snapshot)
                    #endif
                }
        }
    }
}
