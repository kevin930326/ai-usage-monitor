import SwiftUI
import UsageKit
import WidgetKit

@main
struct UsageDesktopWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageDesktopWidget()
    }
}

struct UsageDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageDesktopWidget", provider: UsageTimelineProvider()) { entry in
            UsageWidgetView(snapshot: entry.snapshot, family: entry.family, isSample: entry.isSample, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI 用量")
        .description("顯示 Claude 與 Codex 的剩餘額度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let isSample: Bool
    let family: WidgetFamily
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: SharedSnapshot.sample(), isSample: true, family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(entry(at: .now, family: context.family))
    }

    /// 每 15 分鐘一筆，讓過期變灰與「已重置」在沒有新資料時也會出現；App 有新資料時會要求重新整理。
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date.now
        let entries = (0..<4).map { entry(at: now.addingTimeInterval(Double($0) * 900), family: context.family) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }

    private func entry(at date: Date, family: WidgetFamily) -> UsageEntry {
        if let snapshot = SharedSnapshot.load() {
            return UsageEntry(date: date, snapshot: snapshot, isSample: false, family: family)
        }
        return UsageEntry(date: date, snapshot: SharedSnapshot.sample(now: date), isSample: true, family: family)
    }
}
