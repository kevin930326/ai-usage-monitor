import SwiftUI
import UsageKit
import UsageKitUI

struct HomeView: View {
    @Environment(UsageModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI 用量")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("設定", systemImage: "gearshape") { showSettings = true }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
        }
        .task {
            await model.refresh()
            #if DEBUG
            // 示範模式啟動時直接開一張卡片，方便截圖
            if model.demoScenario != nil { await model.startLiveActivity() }
            // AUM_DEMO_ACTION=restart：開卡後再跑一次捷徑動作，驗證重開流程（FR-10）
            if model.demoScenario != nil, ProcessInfo.processInfo.environment["AUM_DEMO_ACTION"] == "restart" {
                try? await Task.sleep(for: .seconds(1))
                await model.restartLiveActivity()
            }
            #endif
        }
        // 從背景回到前景時自動更新
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConfigured {
            ContentUnavailableView {
                Label("尚未設定中繼", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text("輸入 Cloudflare Worker 網址與讀取密鑰後，就能看到 Claude 與 Codex 的用量。")
            } actions: {
                Button("前往設定") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let snapshot = model.snapshot {
            // 過期、已重置、百分比與剩餘最少的額度都依時間計算；畫面停在前景時沒有其他狀態變化也每分鐘重算
            // （FR-11、FR-26）。TimelineView 在 App 進入背景後不會更新
            TimelineView(.everyMinute) { context in
                UsageList(snapshot: snapshot, errorMessage: model.errorMessage, mode: model.displayMode, now: context.date)
            }
            .refreshable { await model.refresh() }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("無法取得用量", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重試") { Task { await model.refresh() } }
            }
        } else {
            ProgressView("讀取中…")
        }
    }
}

private struct UsageList: View {
    let snapshot: UsageSnapshot
    let errorMessage: String?
    let mode: UsageDisplayMode
    let now: Date

    private var stale: Bool { snapshot.isStale(now: now) }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(UsageColors.notice)
                        .font(.footnote)
                }
            }

            if let tightest = snapshot.tightestWindow(at: now) {
                // 不加「剩餘最少」之類的標題：卡片上的服務圖示＋名稱已經說明是哪一項
                Section {
                    TightestCard(item: tightest, mode: mode, dimmed: stale, now: now)
                }
            }

            if snapshot.hasNoProviders {
                Section {
                    NoProvidersNotice()
                }
            }

            LiveActivitySection()

            ForEach(snapshot.orderedProviderKeys, id: \.self) { key in
                if let provider = snapshot.providers[key] {
                    ProviderSection(key: key, provider: provider, mode: mode, dimmed: stale, now: now)
                }
            }

            Section {
                UpdatedFooter(updatedAt: snapshot.updatedAt, stale: stale)
            }
        }
    }
}

private struct TightestCard: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let dimmed: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                ProviderIcon(item.provider)
                    .foregroundStyle(dimmed ? Color.gray : UsageColors.provider(item.provider))
                    .frame(width: 16, height: 16)
                Text(item.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(mode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Text("\(Int(item.window.displayedPct(mode, at: now).rounded()))%")
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(dimmed ? .secondary : .primary)
                .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: mode, at: now))
            UsageWindowRow(window: item.window, provider: item.provider, display: mode, dimmed: dimmed, now: now)
        }
        .padding(.vertical, 4)
    }
}

/// 開始／結束鎖定畫面卡片（FR-8）。
private struct LiveActivitySection: View {
    @Environment(UsageModel.self) private var model

    var body: some View {
        Section {
            if #unavailable(iOS 18.0) {
                // Widget 擴充最低支援 iOS 18（FR-27），iOS 17 上卡片不會出現
                Label("Live Activity 需要 iOS 18 以上", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if model.liveActivityRunning {
                Button("更新卡片", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Button("結束卡片", systemImage: "stop.circle", role: .destructive) { Task { await model.endLiveActivity() } }
            } else {
                Button("在鎖定畫面顯示", systemImage: "lock.rectangle.on.rectangle") { Task { await model.startLiveActivity() } }
                    .disabled(model.isStartingActivity)
            }
            if let error = model.liveActivityError {
                Text(error).font(.footnote).foregroundStyle(UsageColors.notice)
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("卡片最多顯示 8 小時，結束後可從這裡或捷徑重新開始。")
        }
    }
}

private struct ProviderSection: View {
    let key: String
    let provider: ProviderUsage
    let mode: UsageDisplayMode
    let dimmed: Bool
    let now: Date

    var body: some View {
        Section {
            if let error = provider.error {
                // 單一服務失敗不影響其他服務（FR-12）
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.visibleWindows) { window in
                    UsageWindowRow(window: window, provider: key, display: mode, dimmed: dimmed, now: now)
                        .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text(ProviderInfo.displayName(key))
                if let plan = provider.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

private struct UpdatedFooter: View {
    let updatedAt: Date
    let stale: Bool

    var body: some View {
        HStack {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
            (Text("更新於 ") + Text(updatedAt, style: .relative) + Text("前"))
            if stale {
                Text("· Mac 可能已關機").foregroundStyle(UsageColors.notice)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
