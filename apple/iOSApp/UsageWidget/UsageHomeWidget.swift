import AppIntents
import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

/// 主畫面與鎖定畫面小工具：剩餘最少的額度放最顯眼（FR-15），中、大尺寸再列出各服務的額度。
/// 小工具自己以讀取密鑰呼叫中繼（網址在 App Group、密鑰在共用的 Keychain），
/// 不必等 App 開啟；抓不到時顯示 App Group 中最後一份資料。
struct UsageHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: HomeTimelineProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("AI 用量")
        .description("Claude 與 Codex 的剩餘額度，剩餘最少的額度放最大。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
        // 中型沿用 Live Activity 的版面，它自己留邊界；小、大型在下面自行加 padding
        .contentMarginsDisabled()
    }
}

struct HomeEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let mode: UsageDisplayMode
    /// 沒有資料可顯示時的原因（尚未設定、抓取失敗）
    var message: String?
    /// 有舊資料可顯示、但這次抓不到新資料的原因，顯示在頁尾
    var refreshError: String?
}

struct HomeTimelineProvider: TimelineProvider {
    /// 重新整理間隔。每次 `getTimeline` 都扣 WidgetKit 的每日次數（約 40～70 次）。
    /// 收集器每 5 分鐘寫一次，抓到的資料最多 5 分鐘舊；25 分鐘後重新整理時還沒超過 30 分鐘的過期門檻，
    /// 不會在兩次之間誤顯示「已過期」。一天最多 58 次（與 Mac 桌面小工具的節流相同）。
    static let refreshInterval: TimeInterval = 25 * 60
    /// 資料已過期（Mac 關機或睡眠）時放慢，省下夜間的次數；Mac 醒來後最多晚 1 小時，打開 App 會立即更新。
    static let staleRefreshInterval: TimeInterval = 60 * 60

    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: .now, snapshot: Self.sample(), mode: .remaining)
    }

    /// 小工具庫的預覽：有資料用最後一份，沒有就用範例，不連網。
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(HomeEntry(date: .now, snapshot: SharedStore.loadSnapshot() ?? Self.sample(),
                             mode: UsageSource.displayMode))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        // WidgetKit 的 completion 沒標 Sendable，但可以從任何執行緒呼叫一次
        nonisolated(unsafe) let completion = completion
        Task {
            let now = Date.now
            let entry = await Self.load(now: now)
            let stale = entry.snapshot?.isStale(now: now) ?? true
            let interval = stale ? Self.staleRefreshInterval : Self.refreshInterval
            // 重置與過期的時間點各一筆（不扣次數），讓「已重置」與轉灰準時出現
            let entries = UsageTimelineSchedule.entryDates(now: now, snapshot: entry.snapshot, horizon: interval)
                .map { HomeEntry(date: $0, snapshot: entry.snapshot, mode: entry.mode, message: entry.message,
                                 refreshError: entry.refreshError) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(interval))))
        }
    }

    static func load(now: Date) async -> HomeEntry {
        #if DEBUG
        if let demo = SharedStore.demoScenario.flatMap(DemoData.Scenario.init) {
            return HomeEntry(date: now, snapshot: DemoData.snapshot(for: demo, now: now), mode: DemoData.mode(for: demo))
        }
        #endif
        let mode = UsageSource.displayMode
        guard !UsageSource.relayURL.isEmpty else {
            return HomeEntry(date: now, snapshot: nil, mode: mode, message: "請打開 App 設定中繼")
        }
        do {
            let snapshot = try await UsageSource.fetch(demoScenario: nil)
            SharedStore.saveSnapshot(snapshot)
            return HomeEntry(date: now, snapshot: snapshot, mode: mode)
        } catch {
            // 沒網路、重新開機後尚未解鎖（讀不到 Keychain）等：顯示最後一份，畫面依資料時間轉灰
            let cached = SharedStore.loadSnapshot()
            return HomeEntry(date: now, snapshot: cached, mode: mode,
                             message: cached == nil ? error.localizedDescription : nil,
                             refreshError: cached == nil ? nil : error.localizedDescription)
        }
    }

    /// 預覽與載入中的範例，系統會以遮罩顯示。
    static func sample(now: Date = .now) -> UsageSnapshot {
        UsageSnapshot(updatedAt: now.addingTimeInterval(-120), providers: [
            "claude": ProviderUsage(plan: "Max", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 62, resetsAt: now.addingTimeInterval(6000)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 35, resetsAt: now.addingTimeInterval(3 * 86400)),
            ]),
            "codex": ProviderUsage(plan: "Team", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 12, resetsAt: now.addingTimeInterval(14400)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 48, resetsAt: now.addingTimeInterval(5 * 86400)),
            ]),
        ])
    }
}

/// 小工具上的「更新」按鈕：要求重新整理時間軸，`getTimeline` 會重新抓中繼。
/// 不能只回傳 `.result()` 等系統自己重新整理：實測（iOS 27 模擬器）按鈕執行完系統不會呼叫 `getTimeline`，
/// 畫面停在舊資料。使用者按的才會呼叫，每天幾次，不影響 WidgetKit 的每日次數。
struct ReloadUsageWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "更新 AI 用量小工具"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
        return .result()
    }
}

struct HomeWidgetView: View {
    let entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            ComplicationView(snapshot: entry.snapshot, family: family, mode: entry.mode,
                             staleAfter: UsageSnapshot.staleAfter, now: entry.date)
        default:
            if let snapshot = entry.snapshot {
                let state = UsageActivityState(snapshot: snapshot, mode: entry.mode).withRefreshError(entry.refreshError)
                switch family {
                case .systemSmall:
                    SmallUsageView(state: state, now: entry.date)
                case .systemLarge:
                    LargeUsageView(state: state, now: entry.date)
                default:
                    LockScreenActivityView(state: state, now: entry.date) {
                        RefreshButton(intent: ReloadUsageWidgetIntent())
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title3)
                    Text(entry.message ?? "沒有資料")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        }
    }
}

/// 小：只顯示剩餘最少的額度（FR-15）。
private struct SmallUsageView: View {
    let state: UsageActivityState
    let now: Date

    private var stale: Bool { state.isStale(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = state.tightest(at: now) {
                let pct = item.window.displayedPct(state.mode, at: now)
                HStack(spacing: 5) {
                    ProviderIcon(item.provider)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(stale ? Color.gray : UsageColors.provider(item.provider))
                    Text(item.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityHidden(true)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? .secondary : .primary)
                    .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: state.mode, at: now))
                Text(state.mode.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ProgressView(value: pct, total: 100)
                    .tint(UsageColors.bar(item.window, provider: item.provider, stale: stale, now: now))
                Label {
                    ResetLabel(window: item.window, now: now)
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if state.providers.isEmpty {
                NoProvidersNotice()
            } else {
                Label("沒有資料", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            Spacer(minLength: 0)
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

/// 大：剩餘最少的額度 + 每個服務的所有可見額度（與 App 主畫面相同的 `UsageWindowRow`）。
/// 只用一個服務時（收集器沒有啟用另一個）放大剩餘最少的額度、額度改單欄，不留下半部空白。
private struct LargeUsageView: View {
    let state: UsageActivityState
    let now: Date

    private var stale: Bool { state.isStale(at: now) }
    private var single: Bool { state.providers.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: single ? 16 : 12) {
            if let tightest = state.tightest(at: now) {
                if single {
                    LargeTightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
                } else {
                    TightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
                }
            }
            ForEach(state.providers) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProviderIcon(provider.key)
                            .frame(width: 14, height: 14)
                            .foregroundStyle(stale ? Color.gray : UsageColors.provider(provider.key))
                        Text(provider.displayName)
                            .font(.subheadline.weight(.semibold))
                        if let plan = provider.plan {
                            Text(plan)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let error = provider.error {
                        // 單一服務失敗不影響其他服務（FR-12）
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(UsageColors.notice)
                            .lineLimit(2)
                    } else {
                        // 兩欄，額度多於兩個時換行，不會把頁尾擠出畫面；只有一個服務且額度不多時改單欄
                        let oneColumn = single && provider.windows.count <= 3
                        LazyVGrid(columns: oneColumn ? [GridItem(.flexible())]
                                                     : [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                                  alignment: .leading, spacing: oneColumn ? 14 : 8) {
                            ForEach(provider.windows) { window in
                                UsageWindowRow(window: window, provider: provider.key, display: state.mode,
                                               dimmed: stale, now: now)
                            }
                        }
                    }
                }
            }
            if state.providers.isEmpty {
                // 置中，不要只佔左上角
                Spacer(minLength: 0)
                NoProvidersNotice()
            }
            Spacer(minLength: 0)
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError) {
                RefreshButton(intent: ReloadUsageWidgetIntent())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

/// 大尺寸只有一個服務時剩餘最少的額度：大字百分比與重置倒數。
private struct LargeTightestHeader: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(item.window.label) · \(mode.label)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(item.window.displayedPct(mode, at: now).rounded()))%")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? .secondary : .primary)
                    .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: mode, at: now))
                Spacer()
                ResetLabel(window: item.window, now: now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
