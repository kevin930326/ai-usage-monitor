import SwiftUI
import UsageKit
import WidgetKit

@main
struct UsageComplicationsBundle: WidgetBundle {
    var body: some Widget {
        UsageComplication()
    }
}

struct UsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageComplication", provider: Provider()) { entry in
            ComplicationView(snapshot: entry.snapshot, family: entry.family, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI 用量")
        .description("最吃緊額度的剩餘百分比。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let family: WidgetFamily
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil, family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WatchSnapshotStore.load(), family: context.family))
    }

    /// 每 15 分鐘一筆，另在重置與資料過期（手錶門檻 45 分鐘）的時間點各一筆，資料沒更新時也能準時轉灰或顯示重置後的 100%。
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snapshot = WatchSnapshotStore.load()
        let now = Date.now
        let entries = UsageTimelineSchedule.entryDates(now: now, snapshot: snapshot,
                                                       staleAfter: UsageSnapshot.watchStaleAfter)
            .map { Entry(date: $0, snapshot: snapshot, family: context.family) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}
