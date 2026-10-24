import SwiftUI
import UsageKit
import UsageKitUI

// 面板第三階段：這台 Mac 的 Token 統計卡片（FR-43、FR-46，ADR-0008 第 2 節、ADR-0009 第 4、8 節、ADR-0011 第 4 節）。
// 計算都在 UsageKit（TokenStats.swift），這裡只負責畫。
// 文字一律 primary／secondary；顏色只用在服務圖示、長條與熱力圖（「全部」的熱力圖用藍色色階，不代表任何服務）。

private struct TokenStatsKey: EnvironmentKey {
    static let defaultValue = TokenStatsData.empty
}

extension EnvironmentValues {
    var tokenStats: TokenStatsData {
        get { self[TokenStatsKey.self] }
        set { self[TokenStatsKey.self] = newValue }
    }
}

/// 畫面上的日期：與資料庫的日期鍵一樣用西元曆（使用者選民國曆或佛曆時年份也一致）
enum TokenDateText {
    static func string(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.calendar = TokenCalendar.make()
        f.dateFormat = format
        return f.string(from: date)
    }
}

/// 範圍標籤「這台 Mac」：滑鼠移上去說明不包含的來源（ADR-0011 第 4 節）。
struct ThisMacBadge: View {
    static let help = "只包含這台 Mac 上 Claude Code 與 Codex CLI 的對話紀錄（含它們的桌面 App 與編輯器外掛）。不包含 claude.ai 網頁、手機 App、其他電腦與雲端 session。額度 % 是整個帳號的數字。"

    var body: some View {
        Text("這台 Mac")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help(Self.help)
            .accessibilityLabel("範圍：這台 Mac。不包含網頁、手機 App、其他電腦與雲端 session")
    }
}

struct StatsCardHeader: View {
    var body: some View {
        HStack {
            PanelCardTitle(text: PanelSection.stats.title)
            Spacer(minLength: 4)
            ThisMacBadge()
        }
    }
}

/// 全部／Claude／Codex
struct TokenScopeChips: View {
    let scopes: [TokenScope]
    let selected: TokenScope
    let select: (TokenScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes) { scope in
                Button { select(scope) } label: {
                    HStack(spacing: 3) {
                        if scope != .all {
                            ProviderIcon(scope.rawValue)
                                .foregroundStyle(UsageColors.provider(scope.rawValue))
                                .frame(width: 10, height: 10)
                        }
                        Text(scope.title)
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(scope == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scope.title)
                .accessibilityAddTraits(scope == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 有兩個服務的資料時才需要切換
    static func scopes(_ data: TokenStatsData) -> [TokenScope] {
        let providers = data.providers
        return providers.count > 1 ? [.all] + providers.compactMap { TokenScope(rawValue: $0) } : []
    }
}

/// 卡片內容：第一次使用的骨架、沒有紀錄的提示，或四個數字＋Token 活動＋活動熱力圖。
struct StatsCardContent: View {
    let data: TokenStatsData
    let status: HistoryStore.Status
    let scope: TokenScope
    let range: TokenActivityRange
    let now: Date
    let selectScope: (TokenScope) -> Void
    let selectRange: (TokenActivityRange) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        Group {
            if let message = placeholder {
                StatsSkeleton(message: message)
                    .transition(.opacity)
            } else if !data.hasData {
                VStack(alignment: .leading, spacing: 6) {
                    Text("這台 Mac 還沒有 Claude Code 或 Codex CLI 的紀錄")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 所有紀錄都認不得時也是「沒有資料」，要說明可能是格式改了
                    if data.formatSuspect { FormatSuspectNotice() }
                }
            } else {
                StatsBody(data: data, scope: effectiveScope, range: range, now: now, selectScope: selectScope, selectRange: selectRange)
                    .transition(.opacity)
            }
        }
        .animation(animates ? PanelTiming.crossfade : nil, value: placeholder == nil)
    }

    /// 只有一個服務的資料時固定為「全部」
    private var effectiveScope: TokenScope {
        TokenScopeChips.scopes(data).contains(scope) ? scope : .all
    }

    /// 首次掃描還沒完成、版本或讀取問題時的說明；nil＝可以顯示統計
    private var placeholder: String? {
        switch status {
        case .olderSchema: return "收集器的版本較舊，請重新執行 collector/scripts/install-launchd.sh"
        case .failed: return "無法讀取 Token 統計（history.sqlite3）"
        case .missing: return "正在整理過去的紀錄"
        default: break
        }
        guard !data.firstScanDone else { return nil }
        return data.firstScanProgress.map { "正在整理過去的紀錄（\($0)%）" } ?? "正在整理過去的紀錄"
    }
}

/// 骨架：四格數字、長條與熱力圖的灰色佔位＋說明；打開面板時掃光三次（與額度歷史的骨架共用）。
struct StatsSkeleton: View {
    let message: String

    @Environment(\.panelMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)).frame(height: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<30, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8 + 30 * abs(sin(Double(i) * 0.7)))
                    }
                }
                .frame(height: 40, alignment: .bottom)
            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { ShimmerOverlay(progress: motion.shimmer) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

private struct StatsBody: View {
    let data: TokenStatsData
    let scope: TokenScope
    let range: TokenActivityRange
    let now: Date
    let selectScope: (TokenScope) -> Void
    let selectRange: (TokenActivityRange) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        let summary = TokenSummary(data: data, scope: scope, now: now)
        VStack(alignment: .leading, spacing: 12) {
            let scopes = TokenScopeChips.scopes(data)
            if !scopes.isEmpty {
                TokenScopeChips(scopes: scopes, selected: scope, select: selectScope)
            }
            StatNumbers(summary: summary, scope: scope)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Token 活動").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    TokenRangeChips(selected: range, select: selectRange)
                }
                TokenActivityChart(bars: TokenActivity.bars(data: data, scope: scope, range: range, now: now), scope: scope, range: range)
                    .id("\(scope.rawValue)-\(range.rawValue)")
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("活動熱力圖").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TokenHeatmapView(map: TokenHeatmap(data: data, scope: scope, now: now, weeks: 22), scope: scope)
                    .id(scope)
                    .transition(.opacity)
            }
            if data.formatSuspect { FormatSuspectNotice() }
            if data.skippedLines > 0 {
                Text("部分紀錄無法解析，已略過 \(data.skippedLines) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(animates ? PanelTiming.crossfade : nil, value: scope)
        .animation(animates ? PanelTiming.crossfade : nil, value: range)
    }
}

/// 「紀錄格式可能已改變」的提示（ADR-0009 第 9 節）
struct FormatSuspectNotice: View {
    var body: some View {
        Label(TokenStatsData.formatSuspectNotice, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(UsageColors.notice)
            .fixedSize(horizontal: false, vertical: true)
            .help("最近一次整理對話紀錄時，有很多行認不得（Claude Code 或 Codex CLI 更新後可能改了紀錄格式）。更新收集器後會自動重新判斷。")
    }
}

/// 四個數字：本週 Token（與上週同期比較）、單日最高、最長任務、連續天數。
private struct StatNumbers: View {
    let summary: TokenSummary
    let scope: TokenScope

    @Environment(\.panelMotion) private var motion
    @Environment(\.panelAnimates) private var animates

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("本週 Token", help: weekHelp) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(TokenFormat.short(summary.thisWeek.main)).contentTransition(.numericText())
                        if let change = summary.changePct {
                            Text("\(change >= 0 ? "▲" : "▼")\(Int(abs(change).rounded()))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .help("與上週同一段期間（星期一到上週的今天）相比")
                        }
                    }
                }
                tile("單日最高", detail: summary.bestDay?.day.map(Self.dayText), help: summary.bestDay.map { "\(TokenFormat.full($0.value)) Token" }) {
                    Text(summary.bestDay.map { TokenFormat.short($0.value) } ?? "–").contentTransition(.numericText())
                }
            }
            GridRow {
                tile("最長任務", detail: summary.longestTaskSeconds?.day.map(Self.dayText)) {
                    Text(summary.longestTaskSeconds.map { TokenFormat.duration($0.value) } ?? "–").contentTransition(.numericText())
                }
                tile("連續天數", detail: summary.longestStreak.map { "最長 \($0.value) 天" }) {
                    HStack(spacing: 3) {
                        Text("\(summary.currentStreak) 天").contentTransition(.numericText())
                        if summary.streakIsRecord && summary.currentStreak > 1 {
                            Text("🔥")
                                .font(.callout)
                                .scaleEffect(1 + 0.5 * sin(.pi * motion.streakPop))
                                .accessibilityLabel("創新紀錄")
                        }
                    }
                }
            }
        }
        .animation(animates ? PanelTiming.statsNumbers : nil, value: summary)
    }

    private var weekHelp: String {
        let c = summary.thisWeek
        return """
        合計 \(TokenFormat.full(c.main)) Token
        輸入 \(TokenFormat.full(c.input))
        快取寫入 \(TokenFormat.full(c.cacheWrite))
        輸出 \(TokenFormat.full(c.output))（含推理 \(TokenFormat.full(c.reasoning))）
        快取讀取 \(TokenFormat.full(c.cacheRead))（不計入上方數字）
        """
    }

    static func dayText(_ key: String) -> String {
        guard let date = TokenCalendar.date(key, calendar: .current) else { return key }
        return TokenDateText.string(date, "M/d")
    }

    private func tile(_ title: String, detail: String? = nil, help: String? = nil, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value()
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct TokenRangeChips: View {
    let selected: TokenActivityRange
    let select: (TokenActivityRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TokenActivityRange.allCases) { range in
                Button { select(range) } label: {
                    Text(range.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(range == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == selected ? .isSelected : [])
            }
        }
    }
}
