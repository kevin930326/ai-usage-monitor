import SwiftUI
import WidgetKit

@main
struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageLiveActivity()
        UsageHomeWidget()
    }
}
