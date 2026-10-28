import SwiftUI
import UsageKit
import UsageKitUI

/// 點開選單列後的面板（FR-22、FR-34）：單一長版、卡片式，區塊依設定排序與開關（FR-35）。
/// 保留原本面板的所有資訊：剩餘最少的額度、所有額度、方案、重置倒數或已重置、服務錯誤、
/// 沒有服務的提示、更新時間與資料過期、讀檔錯誤與路徑、結束按鈕。
struct PanelView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// 完整面板開在哪個螢幕：高度上限照那個螢幕（Fable F-11）；選單列面板是 nil
    @Environment(\.panelScreenHeight) private var panelScreenHeight

    /// Debug 截圖工具直接指定動畫進度；一般執行時為 nil，由面板自己驅動
    var fixedMotion: PanelMotion?
    /// ImageRenderer 畫不出 AppKit 的捲動視圖，截圖時關掉捲動
    var scrolls = true

    @State private var motion = PanelMotion.settled
    @State private var visible = false
    @State private var refreshHint: RefreshHint?
    @State private var resetSignature: [String: [String: Date]] = [:]
    /// 面板關閉時加一，讓關閉前排定的動畫完成回呼失效（NFR-8）
    @State private var motionGeneration = 0
    /// Debug 量測用：捲到這個區塊（統計卡片在面板最下方，量測時要看得見才會繪製）
    @State private var scrollTarget: PanelSection?

    private var animates: Bool { visible && !reduceMotion && fixedMotion == nil }

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(animates ? PanelTiming.collapse : nil) { proxy.scrollTo(target, anchor: .bottom) }
                        scrollTarget = nil
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 360)
            .frame(maxHeight: (panelScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 900) - 40)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(behavior)
        } else {
            content.frame(width: 360).modifier(behavior)
        }
    }

    private var behavior: PanelBehavior {
        PanelBehavior(
            motion: fixedMotion ?? motion, animates: animates, live: visible || fixedMotion != nil, colorScheme: colorScheme,
            visible: $visible, onVisibleChange: { isVisible in
                if fixedMotion == nil {
                    PanelVisibility.visibleCount = max(0, PanelVisibility.visibleCount + (isVisible ? 1 : -1))
                }
                if isVisible {
                    // 只在面板看得見時開啟資料庫並查詢（ADR-0009 第 7 節）
                    historyStore.open(now: store.now)
                    playAppear()
                    // 點通知打開面板：捲到對應的卡片並亮一下（減少動態效果時只捲動）
                    playPendingHighlight(visibleNow: true)
                } else {
                    stopAnimations()
                    // 另一個面板還開著時不關（共用同一個資料庫連線）
                    if !PanelVisibility.isVisible { historyStore.close() }
                }
            },
            snapshot: store.snapshot, now: store.now, history: historyStore.history.including(store.snapshot),
            onSnapshotChange: { old, new in
                // 收集器寫入新資料後，「正在更新」之類的提示就不需要了
                if old?.updatedAt != new?.updatedAt {
                    refreshHint = nil
                    // usage.json 有新內容時才重新查詢（收集器同一次執行也寫了歷史）
                    if visible { historyStore.open(now: store.now) }
                }
                detectResets(old: old, new: new)
            },
            onDebugAction: debugAction
        )
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let snapshot = store.snapshot {
                    let stale = snapshot.isStale(now: store.now)
                    let sections = settings.visibleSections
                    ForEach(sections) { section in
                        card(section, snapshot: snapshot, stale: stale)
                            .id(section)
                    }
                    if sections.isEmpty {
                        allHidden
                    }
                }
                footer
            }
            .padding(16)
            // 面板開著時收集器寫入新的紀錄：連續天數創新紀錄也要彈一次
            .onChange(of: historyStore.tokens) {
                if visible { celebrateStreakIfNeeded() }
            }
            // 面板開著時服務轉為異常：橘點呼吸 3 次
            .onChange(of: store.serviceStatus) { old, _ in
                if visible, !statusDisrupted(old) { playStatusPulse() }
            }
            // 面板已經開著時點了通知
            .onReceive(NotificationCenter.default.publisher(for: PanelVisibility.highlightRequested)) { _ in
                playPendingHighlight()
            }
    }

    /// Debug 的效能量測腳本用來觸發動畫（Release 不含）
    private func debugAction(_ action: String) {
        #if DEBUG
        switch action {
        case "refresh": refresh()
        case "glow": if animates { playGlow(store.snapshot?.tightestWindow(at: store.now)?.provider ?? "claude") }
        case "trend-next": switchTrendWindow()
        case "departing":
            // 模擬時間軸上最近的額度重置：圓點在「現在」放大淡出，服務圖示閃光
            if animates, let snapshot = store.snapshot, let next = UpcomingReset.list(snapshot: snapshot, now: store.now).first {
                playDeparting("\(next.provider)/\(next.window.id)")
                playGlow(next.provider)
            }
        case "stats-scroll": scrollTarget = .stats
        case "stats-scope":
            // 依序切換全部／Claude／Codex
            let scopes = TokenScopeChips.scopes(historyStore.tokens.scoped(statsDevice))
            if let i = scopes.firstIndex(of: settings.statsScope), !scopes.isEmpty {
                selectStatsScope(scopes[(i + 1) % scopes.count])
            }
        case "stats-range":
            let all = TokenActivityRange.allCases
            selectStatsRange(all[((all.firstIndex(of: settings.statsRange) ?? 0) + 1) % all.count])
        case "stats-window": showStatsWindow()
        case "status-pulse":
            scrollTarget = .status
            playStatusPulse()
        case "highlight":
            AppActions.pendingHighlight = PanelSection.quota.rawValue
            playPendingHighlight(visibleNow: true)
        case "collapse": settings.collapsed.insert(PanelSection.ring.rawValue)
        case "expand": settings.collapsed.remove(PanelSection.ring.rawValue)
        default: break
        }
        #endif
    }

    // MARK: - 區塊

    @ViewBuilder
    private func card(_ section: PanelSection, snapshot: UsageSnapshot, stale: Bool) -> some View {
        let collapsed = Binding(
            get: { settings.collapsed.contains(section.rawValue) },
            set: { isCollapsed in
                if isCollapsed { settings.collapsed.insert(section.rawValue) } else { settings.collapsed.remove(section.rawValue) }
            }
        )
        switch section {
        case .ring:
            if let item = snapshot.tightestWindow(at: store.now) {
                PanelCard(id: section.rawValue, accessibilityTitle: item.displayName, collapsed: collapsed) {
                    RingCardHeader(item: item, stale: stale)
                } content: {
                    RingCardContent(item: item, stale: stale, now: store.now)
                }
            }
        case .suggest:
            if let suggestion = NextProviderSuggestion(snapshot: snapshot, now: store.now) {
                SuggestBanner(suggestion: suggestion)
                    .animation(animates ? PanelTiming.crossfade : nil, value: suggestion.provider)
            }
        case .quota:
            PanelCard(id: section.rawValue, title: section.title, collapsed: collapsed) {
                QuotaCardContent(snapshot: snapshot, stale: stale, now: store.now, showsMarker: settings.showsExpectedMarker)
            }
        case .resets:
            PanelCard(id: section.rawValue, accessibilityTitle: section.title, collapsed: collapsed) {
                ResetsCardHeader()
            } content: {
                ResetsCardContent(snapshot: snapshot, history: historyStore.history, stale: stale, now: store.now)
            }
        case .trend:
            let options = HistoryWindowOption.options(snapshot)
            if let selected = HistoryWindowOption.resolve(settings.trendWindow, in: options) {
                PanelCard(id: section.rawValue, title: section.title, collapsed: collapsed) {
                    TrendCardContent(options: options, selected: selected, history: historyStore.history, status: historyStore.status,
                                     stale: stale, now: store.now) { option in
                        guard option != selected else { return }
                        settings.trendWindow = option.id
                        playTrend()
                    }
                }
            }
        case .consumption:
            let options = HistoryWindowOption.options(snapshot)
            if let selected = HistoryWindowOption.resolve(settings.consumptionWindow, in: options) {
                PanelCard(id: section.rawValue, accessibilityTitle: section.title, collapsed: collapsed) {
                    ConsumptionCardHeader()
                } content: {
                    ConsumptionCardContent(options: options, selected: selected, history: historyStore.history, status: historyStore.status,
                                           stale: stale, now: store.now) { option in
                        settings.consumptionWindow = option.id
                    }
                }
            }
        case .stats:
            PanelCard(id: section.rawValue, accessibilityTitle: section.title, collapsed: collapsed) {
                StatsCardHeader(devices: historyStore.tokens.devices, scope: statsDevice, now: store.now)
            } content: {
                StatsCardContent(data: historyStore.tokens, status: historyStore.status, device: statsDevice, scope: settings.statsScope,
                                 range: settings.statsRange, measure: settings.statsMeasure, now: store.now, selectDevice: selectStatsDevice,
                                 selectScope: selectStatsScope, selectRange: selectStatsRange, selectMeasure: selectStatsMeasure)
            }
        case .status:
            // 都正常時一行低調顯示；有服務異常或額度用完時才是卡片（FR-45）
            let rows = ServiceStatusRow.rows(snapshot: snapshot, status: store.serviceStatus, now: store.now)
            if !rows.isEmpty {
                if ServiceStatusRow.allQuiet(rows) {
                    ServiceStatusLine(rows: rows)
                } else {
                    PanelCard(id: section.rawValue, title: section.title, collapsed: collapsed) {
                        ServiceStatusCardContent(rows: rows)
                    }
                }
            }
        }
    }

    // MARK: - 第四階段：服務狀態與通知（ADR-0010）

    private func statusDisrupted(_ status: ServiceStatusFile?) -> Bool {
        guard let snapshot = store.snapshot else { return false }
        return ServiceStatusRow.hasDisruption(ServiceStatusRow.rows(snapshot: snapshot, status: status, now: store.now))
    }

    /// 服務異常時橘點呼吸 3 次後停止（3 × 0.8 秒）。卡片隱藏或收合時不播
    private func playStatusPulse() {
        guard animates, settings.visibleSections.contains(.status), !settings.collapsed.contains(PanelSection.status.rawValue),
              statusDisrupted(store.serviceStatus) else { return }
        let generation = motionGeneration
        motion.statusPulse = 0
        withAnimation(PanelTiming.statusPulse) { motion.statusPulse = PanelTiming.statusPulses } completion: {
            guard generation == motionGeneration else { return }
            motion.statusPulse = 0
        }
    }

    /// 點通知打開面板：捲到對應的卡片，卡片亮一下（0.6 秒）。減少動態效果時只捲動
    private func playPendingHighlight(visibleNow: Bool? = nil) {
        // 收起來的那個面板（視圖還在）不要搶走請求（Fable F-10）
        guard visibleNow ?? visible, let id = AppActions.pendingHighlight else { return }
        AppActions.pendingHighlight = nil
        guard let section = PanelSection(rawValue: id), settings.visibleSections.contains(section) else { return }
        scrollTarget = section
        guard animates else { return }
        let generation = motionGeneration
        motion.highlight[id] = 0
        withAnimation(PanelTiming.highlight.delay(0.25)) { motion.highlight[id] = 1 } completion: {
            guard generation == motionGeneration else { return }
            motion.highlight[id] = nil
        }
    }

    /// 第二層的裝置範圍（沒有其他電腦時一律這台 Mac）
    private var statsDevice: TokenDeviceScope {
        historyStore.tokens.devices.resolve(settings.statsDevice)
    }

    /// 切換所有電腦／這台 Mac／其他電腦：與切換服務一樣交叉淡入、圖表重新長出
    private func selectStatsDevice(_ device: TokenDeviceScope) {
        guard device != statsDevice else { return }
        settings.statsDevice = device
        replayStatsCharts()
    }

    /// 切換全部／Claude／Codex：交叉淡入，長條與熱力圖重新長出、數字滾動（ADR-0010 第三階段）
    private func selectStatsScope(_ scope: TokenScope) {
        guard scope != settings.statsScope else { return }
        settings.statsScope = scope
        replayStatsCharts()
    }

    /// 含快取讀取的切換（FR-60）：與切換服務一樣交叉淡入、圖表重新長出
    private func selectStatsMeasure(_ measure: TokenMeasure) {
        guard measure != settings.statsMeasure else { return }
        settings.statsMeasure = measure
        replayStatsCharts()
    }

    private func selectStatsRange(_ range: TokenActivityRange) {
        guard range != settings.statsRange else { return }
        settings.statsRange = range
        guard animates else { return }
        motion.statsBars = 0
        withAnimation(PanelTiming.statsBars) { motion.statsBars = 1 }
    }

    private func replayStatsCharts() {
        guard animates else { return }
        motion.statsBars = 0
        motion.heatmap = 0
        withAnimation(PanelTiming.statsBars) { motion.statsBars = 1 }
        withAnimation(PanelTiming.heatmap) { motion.heatmap = 1 }
    }

    /// 連續天數創新紀錄：🔥 彈一下，每個新紀錄只播一次（記在設定裡）。統計卡片隱藏或收合時不算
    private func celebrateStreakIfNeeded() {
        guard settings.visibleSections.contains(.stats), !settings.collapsed.contains(PanelSection.stats.rawValue) else { return }
        // 連續天數的紀錄只有這台 Mac 有（record_days）
        let summary = TokenSummary(data: historyStore.tokens.scoped(.thisMac), scope: .all, now: store.now)
        guard summary.streakIsRecord, summary.currentStreak > 1, summary.currentStreak > settings.celebratedStreak else { return }
        settings.celebratedStreak = summary.currentStreak
        guard animates else { return }
        let generation = motionGeneration
        motion.streakPop = 0
        withAnimation(PanelTiming.streakPop.delay(0.4)) { motion.streakPop = 1 } completion: {
            guard generation == motionGeneration else { return }
            motion.streakPop = 0
        }
    }

    private func showStatsWindow() {
        NSApplication.shared.activate()
        openWindow(id: StatsWindowView.windowID)
    }

    /// 切換走勢的額度：新曲線重新由左往右描繪（舊曲線交叉淡出）。
    private func playTrend() {
        guard animates else { return }
        motion.trend = 0
        withAnimation(PanelTiming.trend) { motion.trend = 1 }
    }

    /// Debug 量測用：切到下一個可選的額度
    private func switchTrendWindow() {
        guard let snapshot = store.snapshot else { return }
        let options = HistoryWindowOption.options(snapshot)
        guard let current = HistoryWindowOption.resolve(settings.trendWindow, in: options),
              let index = options.firstIndex(of: current), options.count > 1 else { return }
        settings.trendWindow = options[(index + 1) % options.count].id
        playTrend()
    }

    /// 走勢或額度消耗目前顯示骨架畫面（歷史不足）：打開面板時才需要掃光。
    private var showsSkeleton: Bool {
        guard let snapshot = store.snapshot else { return false }
        let sections = Set(settings.visibleSections).subtracting(settings.collapsed.compactMap(PanelSection.init))
        let options = HistoryWindowOption.options(snapshot)
        let history = historyStore.history
        let readable = historyStore.status.canRead
        if sections.contains(.trend), let o = HistoryWindowOption.resolve(settings.trendWindow, in: options),
           !(readable && QuotaTrend(provider: o.provider, window: o.window, history: history, now: store.now).hasEnoughData) {
            return true
        }
        if sections.contains(.consumption), let o = HistoryWindowOption.resolve(settings.consumptionWindow, in: options),
           !(readable && QuotaConsumption(provider: o.provider, windowID: o.window.id, history: history, now: store.now).hasEnoughData) {
            return true
        }
        // 統計卡片在首次掃描完成前也是骨架
        if sections.contains(.stats), !(readable && historyStore.tokens.firstScanDone) {
            return true
        }
        return false
    }

    private var allHidden: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所有區塊都已隱藏").font(.callout)
            Button("打開設定", action: showSettings)
                .buttonStyle(PanelPillButtonStyle())
        }
        .padding(14)
    }

    // MARK: - 頁首與頁尾

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AI 用量").font(.title3.weight(.bold))
            if let snapshot = store.snapshot {
                UpdatedStatus(updatedAt: snapshot.updatedAt, stale: snapshot.isStale(now: store.now), flash: motion.dotFlash)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Button("重新讀取", systemImage: "arrow.clockwise", action: refresh)
                    .buttonStyle(PanelIconButtonStyle(rotation: .degrees(360 * (fixedMotion ?? motion).refreshTurns)))
                    .help("重新讀取 usage.json")
                Button("設定", systemImage: "gearshape", action: showSettings)
                    .buttonStyle(PanelIconButtonStyle())
                    .help("設定")
                Button("結束", systemImage: "power") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("結束 AI 用量")
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if settings.visibleSections.contains(.stats), historyStore.tokens.hasData {
            Button(action: showStatsWindow) {
                Text("完整統計視窗 →").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("一年熱力圖、30 天長條、各模型與時段分布")
        }
        if let status = store.snapshot?.localStatus, status.lowDisk {
            // 收集器在磁碟剩餘空間不足時暫停寫 history.sqlite3（ADR-0014 LT-06）；額度照常更新
            Label("磁碟空間不足\(status.diskFreeMB.map { "（剩 \($0) MB）" } ?? "")，暫停記錄額度歷史與 Token 統計；用量照常更新",
                  systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(UsageColors.notice)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let status = store.snapshot?.localStatus, let resetAt = status.historyResetAt {
            // 收集器發現 history.sqlite3 損毀，改名保留並建立新檔（ADR-0014 D-1）；7 天內顯示
            Label {
                Text("history.sqlite3 損毀，\(resetAt, format: .dateTime.month(.defaultDigits).day().hour().minute()) 已改名保留並重新記錄；可從每週備份還原（docs/runbook.md）")
            } icon: {
                Image(systemName: "externaldrive.badge.xmark")
            }
            .font(.caption)
            .foregroundStyle(UsageColors.notice)
            .fixedSize(horizontal: false, vertical: true)
            .help(status.historyKeptAs.map { "保留的舊檔：\($0)（和 history.sqlite3 同一個資料夾）" } ?? "")
        }
        if let refreshHint {
            Text(refreshHint.text)
                .font(.caption)
                .foregroundStyle(refreshHint.isProblem ? UsageColors.notice : .secondary)
                .transition(.opacity)
        }
        if let error = store.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                Text(store.locator.usageFile.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 動作與動畫

    /// 重讀 usage.json，並請 launchd 立即執行收集器（FR-50；60 秒內一次、24 小時最多 100 次）。
    /// 收集器寫完後資料夾監看會自動重讀，不需要輪詢。
    private func refresh() {
        let before = store.snapshot?.updatedAt
        store.reload()
        let changed = store.snapshot?.updatedAt != before
        Task {
            let outcome = await CollectorTrigger.shared.trigger(usesCustomHome: store.usesCustomHome)
            let hint = changed ? nil : RefreshHint(outcome)
            withAnimation(animates ? PanelTiming.reducedFade : nil) { refreshHint = hint }
        }
        guard animates else { return }
        let generation = motionGeneration
        withAnimation(PanelTiming.refreshSpin) {
            motion.refreshTurns += 1
        } completion: {
            // 旋轉途中關閉面板時不再接著閃狀態點
            guard generation == motionGeneration else { return }
            withAnimation(PanelTiming.dotFlash) { motion.dotFlash = 1 } completion: { motion.dotFlash = 0 }
        }
    }

    private func showSettings() {
        NSApplication.shared.activate()
        openSettings()
    }

    /// 打開面板：圓環與用量條從 0 長到目前位置，預期標記稍後淡入。
    private func playAppear() {
        resetSignature = Self.signature(store.snapshot, now: store.now)
        guard animates else {
            motion = .settled
            return
        }
        var start = PanelMotion.hidden
        start.refreshTurns = motion.refreshTurns
        motion = start
        withAnimation(PanelTiming.appear) { motion.appear = 1 }
        withAnimation(PanelTiming.marker) { motion.marker = 1 }
        withAnimation(PanelTiming.trend) { motion.trend = 1 }
        withAnimation(PanelTiming.suggest) { motion.suggest = 1 }
        withAnimation(PanelTiming.timeline) { motion.timeline = 1 }
        withAnimation(PanelTiming.statsBars) { motion.statsBars = 1 }
        withAnimation(PanelTiming.heatmap) { motion.heatmap = 1 }
        // 骨架掃光只在有骨架時播放（三次後停止），沒有骨架時不讓整個面板多重繪 3.6 秒
        if showsSkeleton {
            withAnimation(PanelTiming.shimmer) { motion.shimmer = PanelTiming.shimmerPasses }
        }
        celebrateStreakIfNeeded()
        playStatusPulse()
    }

    /// 面板關閉：停止所有動畫並回到靜止狀態，關閉期間不播放任何東西（NFR-8）。
    private func stopAnimations() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        motionGeneration += 1
        withTransaction(transaction) {
            motion = .settled
            refreshHint = nil
        }
    }

    /// 額度重置時（`resets_at` 往後移，或時間到了顯示「已重置」），對應的服務圖示閃一下光芒。
    /// 只在面板開啟時播放；關閉期間發生的不補播。
    private func detectResets(old: UsageSnapshot?, new: UsageSnapshot?) {
        let next = Self.signature(new, now: store.now)
        defer { resetSignature = next }
        guard animates else { return }
        for (provider, windows) in next {
            let previous = resetSignature[provider] ?? [:]
            let reset = windows.filter { id, resetsAt in
                guard let before = previous[id] else { return false }
                return resetsAt > before
            }
            if !reset.isEmpty { playGlow(provider) }
            for id in reset.keys { playDeparting("\(provider)/\(id)") }
        }
    }

    /// 時間軸上重置的圓點在「現在」的位置放大淡出。
    private func playDeparting(_ key: String) {
        motion.departing[key] = 0
        withAnimation(PanelTiming.departing) {
            motion.departing[key] = 1
        } completion: {
            motion.departing[key] = nil
        }
    }

    private func playGlow(_ provider: String) {
        motion.glow[provider] = 0
        withAnimation(PanelTiming.glow) {
            motion.glow[provider] = 1
        } completion: {
            motion.glow[provider] = 0
        }
    }

    /// 各服務各額度「目前這一輪的重置時間」：已重置的額度以 distantFuture 表示，換輪時值會變大。
    private static func signature(_ snapshot: UsageSnapshot?, now: Date) -> [String: [String: Date]] {
        guard let snapshot else { return [:] }
        var result: [String: [String: Date]] = [:]
        for (key, provider) in snapshot.providers where provider.error == nil {
            var windows: [String: Date] = [:]
            for window in provider.visibleWindows {
                guard let resetsAt = window.resetsAt else { continue }
                windows[window.id] = window.isReset(at: now) ? .distantFuture : resetsAt
            }
            result[key] = windows
        }
        return result
    }
}

/// 面板共用的環境值、可見度追蹤與資料變更的處理（捲動與截圖兩種版面共用）。
private struct PanelBehavior: ViewModifier {
    let motion: PanelMotion
    let animates: Bool
    let live: Bool
    let colorScheme: ColorScheme
    @Binding var visible: Bool
    let onVisibleChange: (Bool) -> Void
    let snapshot: UsageSnapshot?
    let now: Date
    let history: QuotaHistory
    let onSnapshotChange: (UsageSnapshot?, UsageSnapshot?) -> Void
    let onDebugAction: (String) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.panelMotion, motion)
            .environment(\.panelAnimates, animates)
            .environment(\.panelLive, live)
            .environment(\.quotaHistory, history)
            .animation(animates ? PanelTiming.colorScheme : nil, value: colorScheme)
            .background(WindowVisibilityReader { visible = $0 }.frame(width: 0, height: 0))
            .onChange(of: visible) { _, isVisible in onVisibleChange(isVisible) }
            .onChange(of: snapshot) { old, new in onSnapshotChange(old, new) }
            .onChange(of: now) { _, _ in onSnapshotChange(snapshot, snapshot) }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugAction.notification)) { note in
                if let action = note.object as? String { onDebugAction(action) }
            }
            #endif
    }
}

/// 頁首的更新狀態：綠點＋「N 分鐘前更新」；過期時改為「資料已過期 · HH:mm 更新」（FR-11）。
struct UpdatedStatus: View {
    let updatedAt: Date
    let stale: Bool
    var flash: Double = 0

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stale ? Color.gray : Color.green)
                .frame(width: 7, height: 7)
                .modifier(FlashEffect(progress: flash))
            Group {
                if stale {
                    Text("資料已過期 · ") + Text(updatedAt, format: .dateTime.hour().minute()) + Text(" 更新")
                } else {
                    HStack(spacing: 0) {
                        LiveRelativeText(date: updatedAt)
                        Text("前更新")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(stale ? AnyShapeStyle(UsageColors.notice) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        }
    }
}

/// 頁首的圖示按鈕。自己畫（不用 AppKit 的按鈕），ImageRenderer 才能截圖。
struct PanelIconButtonStyle: ButtonStyle {
    var rotation: Angle = .zero

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .rotationEffect(rotation)
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct PanelPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
    }
}

extension EnvironmentValues {
    /// 面板所在螢幕的可見高度（完整面板用；nil 時用主螢幕）
    @Entry var panelScreenHeight: Double?
}
