import SwiftUI
import UsageKit
import UsageKitUI

/// 手錶 App（FR-29）：最吃緊的一項與所有服務的可見額度、重置倒數。
struct UsageListView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI 用量")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConfigured {
            ContentUnavailableView("請在 iPhone 設定", systemImage: "iphone",
                                   description: Text("在 iPhone 的 AI 用量 App 設定中繼後，會自動同步到手錶。"))
        } else if let snapshot = model.snapshot {
            UsageList(snapshot: snapshot, errorMessage: model.errorMessage)
                .refreshable { await model.refresh() }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("無法取得用量", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重試") { Task { await model.refresh() } }
                    .disabled(model.isLoading)
            }
        } else {
            ProgressView()
        }
    }
}

private struct UsageList: View {
    let snapshot: UsageSnapshot
    let errorMessage: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let stale = snapshot.isStale(now: now)
            List {
                if let item = snapshot.tightestWindow(at: now) {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(item.window.effectiveRemainingPct(at: now).rounded()))%")
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(stale ? .secondary : .primary)
                            Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label) 剩餘")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(snapshot.orderedProviderKeys, id: \.self) { key in
                    if let provider = snapshot.providers[key] {
                        Section(ProviderInfo.displayName(key)) {
                            if let error = provider.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(UsageColors.notice)
                            } else {
                                ForEach(provider.visibleWindows) { window in
                                    WatchWindowRow(window: window, provider: key, stale: stale, now: now)
                                }
                            }
                        }
                    }
                }
                Section {
                    Group {
                        if stale {
                            Text("資料已過期 · ") + Text(snapshot.updatedAt, style: .time) + Text(" 更新")
                        } else {
                            Text(snapshot.updatedAt, style: .relative) + Text("前更新")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(stale ? UsageColors.notice : .secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(UsageColors.notice)
                    }
                }
            }
        }
    }
}

private struct WatchWindowRow: View {
    let window: UsageWindow
    let provider: String
    let stale: Bool
    let now: Date

    private var pct: Double { window.effectiveRemainingPct(at: now) }
    /// 進度條顏色（FR-16）；百分比文字一律 primary
    private var tint: Color { UsageColors.bar(window, provider: provider, stale: stale, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .monospacedDigit()
            }
            Gauge(value: pct, in: 0...100) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(tint)
            Group {
                if window.isReset(at: now) {
                    Text("已重置")
                } else if let resetsAt = window.resetsAt {
                    Text("重置 ") + Text(resetsAt, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
