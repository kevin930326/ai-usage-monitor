import ActivityKit
import SwiftUI
import UsageKit
import WidgetKit

struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            Text("AI 用量")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text("AI 用量") }
            } compactLeading: {
                Text("AI")
            } compactTrailing: {
                Text("--")
            } minimal: {
                Text("AI")
            }
        }
    }
}
