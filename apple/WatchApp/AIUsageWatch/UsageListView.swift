import SwiftUI
import UsageKit
import UsageKitUI

/// 手錶 App（FR-29）：剩餘最少的額度與所有服務的可見額度、重置倒數。
struct UsageListView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            UsageListContent(isConfigured: model.isConfigured, snapshot: model.snapshot, errorMessage: model.errorMessage,
                             settingsError: model.settingsError, isLoading: model.isLoading) { await model.refresh() }
                .navigationTitle("AI 用量")
        }
    }
}

/// 列表的各種狀態（不直接讀 WatchModel，Debug 截圖可以指定每種狀態）
struct UsageListContent: View {
    let isConfigured: Bool
    let snapshot: UsageSnapshot?
    let errorMessage: String?
    /// iPhone 傳來的設定存不進 Keychain（整合審查 D-a）：每個狀態都要看得到
    let settingsError: String?
    let isLoading: Bool
    let refresh: () async -> Void

    var body: some View {
        if !isConfigured {
            ContentUnavailableView {
                Label("請在 iPhone 設定", systemImage: "iphone")
            } description: {
                Text(settingsError ?? "在 iPhone 的 AI 用量 App 設定中繼後，會自動同步到手錶。")
            }
        } else if let snapshot {
            UsageList(snapshot: snapshot, messages: [errorMessage, settingsError].compactMap { $0 })
                .refreshable { await refresh() }
        } else if let error = errorMessage ?? settingsError {
            ContentUnavailableView {
                Label("無法取得用量", systemImage: "exclamationmark.triangle")
            } description: {
                Text([error, errorMessage == nil ? nil : settingsError].compactMap { $0 }.joined(separator: "\n"))
            } actions: {
                Button("重試") { Task { await refresh() } }
                    .disabled(isLoading)
            }
        } else {
            ProgressView()
        }
    }
}

private struct UsageList: View {
    let snapshot: UsageSnapshot
    /// 抓取錯誤與設定錯誤，列在最下方
    let messages: [String]

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let stale = snapshot.isStale(now: now, after: UsageSnapshot.watchStaleAfter)
            List {
                if let item = snapshot.tightestWindow(at: now) {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(item.window.effectiveRemainingPct(at: now).rounded()))%")
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(stale ? .secondary : .primary)
                            Text("\(item.displayName) 剩餘")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.leastRemainingAccessibilityLabel(at: now))
                    }
                }
                if snapshot.hasNoProviders {
                    Section {
                        NoProvidersNotice()
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
                            // 同重置倒數：不用每秒更新的相對時間文字，由 TimelineView 每分鐘更新
                            Text(ResetCountdown.updatedText(since: snapshot.updatedAt, now: now))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(stale ? UsageColors.notice : .secondary)
                    ForEach(messages, id: \.self) { message in
                        Text(message).font(.footnote).foregroundStyle(UsageColors.notice)
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
                } else if let resetsAt = window.resetsAt, let countdown = ResetCountdown.text(until: resetsAt, now: now) {
                    // 不用 Text(resetsAt, style: .relative)：它每秒更新，在 watchOS 的 List 列裡會讓
                    // 版面不斷重算、CPU 吃滿。`now` 來自外層的 TimelineView(.everyMinute)，每分鐘更新一次
                    Text("重置 \(countdown)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
