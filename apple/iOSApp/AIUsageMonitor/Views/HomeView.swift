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
            // AUM_DEMO_ACTION=settings：直接打開設定畫面（截圖用）
            if model.demoScenario != nil, ProcessInfo.processInfo.environment["AUM_DEMO_ACTION"] == "settings" {
                showSettings = true
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
                UsageList(snapshot: snapshot, errorMessage: model.errorMessage, mode: model.displayMode, now: context.date,
                          remoteAgents: model.remoteAgents.filter { $0.isShown(at: Int64(context.date.timeIntervalSince1970 * 1000)) })
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
    var remoteAgents: [RemoteAgent] = []

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

            if !remoteAgents.isEmpty {
                RemoteAgentsSection(agents: remoteAgents)
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

/// 其他電腦的 AI 狀態（ADR-0019 第 2 節）：需要你、出錯、工作中、完成，依狀態排序。打開或下拉更新時讀，沒有推播
private struct RemoteAgentsSection: View {
    let agents: [RemoteAgent]

    var body: some View {
        Section {
            ForEach(agents, id: \.id) { agent in
                HStack {
                    Label(agent.text, systemImage: agent.state == .needsYou ? "hand.raised.fill" : "desktopcomputer")
                        .foregroundStyle(agent.state == .needsYou ? UsageColors.notice : .primary)
                    Spacer()
                    if agent.sessions > 1 {
                        Text("\(agent.sessions) 個").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("其他電腦")
        } footer: {
            Text("打開 App 或下拉更新時讀取，不會即時通知。")
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
            // 服務狀態頁的事故（ADR-0018 第 4 節）：只顯示 minor 以上（維護不算異常）；額度讀取失敗時也顯示；
            // 連結只接受官方狀態頁
            ForEach(Array((provider.incidents ?? []).filter(\.isDisruption).enumerated()), id: \.offset) { _, incident in
                IncidentRow(incident: incident)
            }
            if let error = provider.error {
                // 單一服務失敗不影響其他服務（FR-12）
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.visibleWindows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        UsageWindowRow(window: window, provider: key, display: mode, dimmed: dimmed, now: now)
                        // 會在重置前用完時（ADR-0018 第 3 節）：收集器算好的預測，iPhone 沒有歷史
                        if let forecast = QuotaForecast.current(window: window, provider: key, history: nil, stale: dimmed, now: now) {
                            Label(forecast.line(now: now), systemImage: forecast.urgent ? "exclamationmark.circle.fill" : "speedometer")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(forecast.urgent ? UsageColors.critical : UsageColors.notice)
                                .accessibilityLabel(forecast.spokenLine(now: now))
                        }
                    }
                    .padding(.vertical, 2)
                }
                // 重置次數卷（FR-58）：0 張時不顯示
                if let credits = provider.resetCredits, let summary = credits.summary(at: now) {
                    Label(summary, systemImage: "ticket")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(credits.accessibilityLabel(at: now) ?? summary)
                        .accessibilityHint(credits.detailLines(at: now).joined(separator: "，"))
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

private struct IncidentRow: View {
    let incident: ServiceIncident

    var body: some View {
        let label = Label("服務異常：\(incident.name)", systemImage: "cross.case.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(UsageColors.notice)
        if let link = incident.link {
            Link(destination: link) { label }
                .accessibilityHint("在 Safari 打開事故頁")
        } else {
            label
        }
    }
}

private struct UpdatedFooter: View {
    let updatedAt: Date
    let stale: Bool

    var body: some View {
        HStack {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
            (Text("更新於 ") + Text.relative(to: updatedAt) + Text("前"))
            if stale {
                Text("· Mac 可能已關機").foregroundStyle(UsageColors.notice)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
