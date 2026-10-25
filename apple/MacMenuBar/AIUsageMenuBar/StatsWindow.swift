import SwiftUI
import UsageKit
import UsageKitUI

// 完整統計視窗（FR-44、ADR-0008 第 4 節）：一年熱力圖、30 天疊加長條、各模型、時段分布、個人紀錄。
// 打開時另開一個短暫的資料庫連線讀完就關；關閉視窗時釋放資料（ADR-0009 第 7 節）。
// 可調整大小，最小 720×520。

struct StatsWindowView: View {
    static let windowID = "stats"

    let historyStore: HistoryStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var data: TokenStatsData?
    @State private var loading = false
    @State private var scope: TokenScope = .all
    @State private var motion = PanelMotion.settled
    @State private var visible = false

    /// Debug 截圖直接給資料與動畫進度
    var fixedData: TokenStatsData?
    var fixedMotion: PanelMotion?
    var now: Date = RenderClock.now
    /// ImageRenderer 畫不出 AppKit 的捲動視圖，截圖時關掉捲動
    var scrolls = true

    /// 所有裝置的資料；畫面用依裝置範圍篩選後的 `shown`
    private var raw: TokenStatsData? { fixedData ?? data }
    /// 第二層的裝置範圍與面板共用（PanelSettings）
    private var device: TokenDeviceScope { (raw?.devices ?? .none).resolve(PanelSettings.shared.statsDevice) }
    private var shown: TokenStatsData? { raw?.scoped(device) }
    private var animates: Bool { visible && !reduceMotion && fixedMotion == nil }

    var body: some View {
        Group {
            if let shown, shown.hasData {
                content(shown)
            } else if let shown, !shown.firstScanDone {
                message(shown.firstScanProgress.map { "正在整理過去的紀錄（\($0)%）" } ?? "正在整理過去的紀錄")
            } else if let shown, let raw {
                VStack(spacing: 8) {
                    if raw.devices.enabled { deviceMenu(raw.devices) }
                    Text(TokenStatsData.emptyText(device, devices: raw.devices))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if shown.formatSuspect { FormatSuspectNotice() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                message("正在讀取…")
            } else {
                message("無法讀取 Token 統計（history.sqlite3）")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.panelMotion, fixedMotion ?? motion)
        .environment(\.panelAnimates, animates)
        // 換外觀（FR-51）時與面板相同的過渡
        .animation(animates ? PanelTiming.colorScheme : nil, value: colorScheme)
        .background {
            if fixedData == nil {
                WindowVisibilityReader { isVisible in
                    visible = isVisible
                    if isVisible { load() } else { release() }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 打開（或從其他 Space 切回來）時重新讀取；長條與熱力圖再長一次
    private func load() {
        guard data == nil, !loading else { return }
        loading = true
        let store = historyStore
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { store.loadFullTokenStats() }.value
            loading = false
            guard visible else { return }
            data = loaded
            replayCharts()
        }
    }

    /// 長條與熱力圖再長一次（打開視窗、切換裝置）
    private func replayCharts() {
        guard animates else {
            motion = .settled
            return
        }
        motion.statsBars = 0
        motion.heatmap = 0
        withAnimation(PanelTiming.statsBars) { motion.statsBars = 1 }
        withAnimation(PanelTiming.heatmap) { motion.heatmap = 1 }
    }

    /// 關閉視窗：釋放所有資料，下次打開再讀
    private func release() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            data = nil
            motion = .settled
        }
    }

    private func deviceMenu(_ devices: TokenDevices) -> some View {
        TokenDeviceMenu(devices: devices, selected: device, now: now) { selected in
            PanelSettings.shared.statsDevice = selected
            replayCharts()
        }
    }

    private func content(_ data: TokenStatsData) -> some View {
        let devices = data.devices
        let scopes = TokenScopeChips.scopes(data)
        let scope = scopes.contains(self.scope) ? self.scope : .all
        let summary = TokenSummary(data: data, scope: scope, now: now)
        let page = VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("完整統計").font(.title2.weight(.bold))
                if devices.enabled {
                    deviceMenu(devices)
                } else {
                    ThisMacBadge()
                }
                Spacer()
                if !scopes.isEmpty {
                    TokenScopeChips(scopes: scopes, selected: scope) { self.scope = $0 }
                }
            }
            RecordsRow(summary: summary)
            section("活動熱力圖（一年）") {
                TokenHeatmapView(map: TokenHeatmap(data: data, scope: scope, now: now, weeks: 53), scope: scope)
                    .id(scope)
            }
            section("最近 30 天") {
                TokenActivityChart(bars: TokenActivity.bars(data: data, scope: scope, range: .days30, now: now),
                                   scope: scope, range: .days30, height: 140)
                    .id(scope)
            }
            HStack(alignment: .top, spacing: 24) {
                section("各模型") { ModelList(models: TokenBreakdown.models(data: data, scope: scope)) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                // 每小時資料只有這台 Mac 的（其他電腦只上傳每日加總）
                section(device == .thisMac || !devices.enabled ? "一天中的時段（最近 90 天）" : "一天中的時段（最近 90 天，只有這台 Mac）") {
                    if case .device = device {
                        Text("其他電腦只上傳每日加總，沒有時段資料")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        HourChart(hours: TokenBreakdown.hours(data: data, scope: scope))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if data.devices.uploadRevoked { UploadRevokedNotice() }
            Text(footnote(data))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .animation(animates ? PanelTiming.crossfade : nil, value: scope)
        .animation(animates ? PanelTiming.crossfade : nil, value: device)
        return Group {
            if scrolls { ScrollView { page } } else { page }
        }
    }

    private func footnote(_ data: TokenStatsData) -> String {
        let retention = data.retentionDays == 0 ? "永久保留" : "保留 \(data.retentionDays) 天"
        var text = "Token 不含快取讀取（滑鼠移到數字上可看明細）。每日資料\(retention)，"
        text += device == .thisMac ? "個人紀錄與累計不受保留期間影響。"
            : "\(data.devices.title(device))的個人紀錄與累計只算最近一年的每日資料。其他電腦的數字是它們最後一次上傳的每日加總。"
        if data.formatSuspect { text += TokenStatsData.formatSuspectNotice + "。" }
        if data.skippedLines > 0 { text += "部分紀錄無法解析，已略過 \(data.skippedLines) 行。" }
        return text
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// 個人紀錄：本週、單日最高、最長任務、最長連續、累計
private struct RecordsRow: View {
    let summary: TokenSummary

    var body: some View {
        HStack(spacing: 12) {
            tile("本週 Token", TokenFormat.short(summary.thisWeek.main),
                 summary.changePct.map { "\($0 >= 0 ? "▲" : "▼")\(Int(abs($0).rounded()))% 與上週同期" },
                 help: TokenFormat.full(summary.thisWeek.main))
            tile("單日最高", summary.bestDay.map { TokenFormat.short($0.value) } ?? "–", summary.bestDay?.day.map(StatNumbersText.day),
                 help: summary.bestDay.map { TokenFormat.full($0.value) })
            tile("最長任務", summary.longestTaskSeconds.map { TokenFormat.duration($0.value) } ?? "–",
                 summary.longestTaskSeconds?.day.map(StatNumbersText.day))
            tile("最長連續", summary.longestStreak.map { "\($0.value) 天" } ?? "–", "目前 \(summary.currentStreak) 天")
            tile("累計 Token", summary.total.map { TokenFormat.short($0.value) } ?? "–", summary.total.map { TokenFormat.full($0.value) },
                 help: summary.total.map { TokenFormat.full($0.value) })
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String?, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help.map { "\($0) Token" } ?? "")
        .accessibilityElement(children: .combine)
    }
}

enum StatNumbersText {
    static func day(_ key: String) -> String {
        guard let date = TokenCalendar.date(key, calendar: .current) else { return key }
        return TokenDateText.string(date, "yyyy/M/d")
    }
}

/// 各模型：橫條（相對最多的模型），右邊是主數字；滑鼠移上去看四種 Token。
private struct ModelList: View {
    let models: [TokenModelTotal]

    var body: some View {
        let peak = Double(max(models.first?.counts.main ?? 1, 1))
        VStack(alignment: .leading, spacing: 6) {
            if models.isEmpty {
                Text("沒有資料").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(models.prefix(10)) { item in
                HStack(spacing: 8) {
                    Text(item.model).font(.callout).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(UsageColors.provider(item.provider))
                            .frame(width: max(geo.size.width * CGFloat(Double(item.counts.main) / peak), 2))
                    }
                    .frame(height: 8)
                    Text(TokenFormat.short(item.counts.main)).font(.callout).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                .help("合計 \(TokenFormat.full(item.counts.main))：輸入 \(TokenFormat.full(item.counts.input))、快取寫入 \(TokenFormat.full(item.counts.cacheWrite))、輸出 \(TokenFormat.full(item.counts.output))、快取讀取 \(TokenFormat.full(item.counts.cacheRead))")
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// 一天中的時段：24 根長條（本機時間）
private struct HourChart: View {
    let hours: [Int64]

    @Environment(\.panelMotion) private var motion
    @State private var hovered: Int?

    var body: some View {
        let peak = Double(max(hours.max() ?? 0, 1))
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let slot = size.width / 24
                for (hour, value) in hours.enumerated() {
                    let grow = TokenBarsCanvas.grow(motion.statsBars, index: hour, count: 24)
                    let h = value > 0 ? max(CGFloat(Double(value) / peak) * size.height * CGFloat(grow), 1) : 0
                    let rect = CGRect(x: slot * CGFloat(hour) + 1.5, y: size.height - h, width: slot - 3, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(Color.primary.opacity(hovered == nil || hovered == hour ? 0.6 : 0.3)))
                }
            }
            .frame(height: 100)
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        if case let .active(point) = phase { hovered = TokenBarsCanvas.index(at: point.x, count: 24, width: geo.size.width) } else { hovered = nil }
                    }
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h) 時").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(hovered.map { "\($0) 時：\(TokenFormat.short(hours[$0]))" } ?? "每根一小時（本機時間）")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("一天中的時段：最多在 \(hours.firstIndex(of: hours.max() ?? 0) ?? 0) 時")
    }
}
