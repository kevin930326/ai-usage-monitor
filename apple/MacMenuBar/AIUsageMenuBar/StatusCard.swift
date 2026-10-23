import AppKit
import SwiftUI
import UsageKit
import UsageKitUI

// MARK: - 服務狀態（FR-45、ADR-0008 第 2 節第 8 項）

/// 面板上一個服務的狀態列需要的值。
struct ServiceStatusRow: Equatable, Identifiable {
    var provider: String
    var health: ServiceHealth
    var quotaExhausted: Bool

    var id: String { provider }

    var explanation: String? {
        ServiceStatusSummary.explanation(health: health, quotaExhausted: quotaExhausted, provider: provider)
    }

    /// 快照中的服務（依顯示順序）各一列
    static func rows(snapshot: UsageSnapshot, status: ServiceStatusFile?, now: Date) -> [ServiceStatusRow] {
        snapshot.orderedProviderKeys.map { key in
            ServiceStatusRow(provider: key, health: ServiceStatusSummary.health(status, provider: key, now: now),
                             quotaExhausted: ServiceStatusSummary.quotaExhausted(snapshot, provider: key, now: now))
        }
    }

    /// 所有服務都正常、也沒有額度用完：只顯示一行
    static func allQuiet(_ rows: [ServiceStatusRow]) -> Bool {
        rows.allSatisfy { !$0.health.isProblem && !$0.quotaExhausted }
    }

    /// 有服務異常（橘點呼吸 3 次）
    static func hasDisruption(_ rows: [ServiceStatusRow]) -> Bool {
        rows.contains { $0.health.isDisruption }
    }
}

/// 狀態頁網址：App 自己決定，不用檔案裡的字串（收集器寫的檔案只當資料）
enum ServiceStatusPage {
    static func url(_ provider: String) -> URL? {
        switch provider {
        case "claude": URL(string: "https://status.claude.com")
        case "codex": URL(string: "https://status.openai.com")
        default: nil
        }
    }
}

/// 正常時的一行（低調、沒有收合箭頭）：「● 服務正常 · Claude、Codex」；狀態不明時灰點「服務狀態暫時無法取得」。
struct ServiceStatusLine: View {
    let rows: [ServiceStatusRow]

    private var unknown: Bool { rows.allSatisfy { $0.health == .unknown } }

    private var text: String {
        if unknown { return "服務狀態暫時無法取得" }
        let names = rows.filter { $0.health == .operational }.map { ProviderInfo.displayName($0.provider) }
        let rest = rows.contains { $0.health == .unknown } ? "（其他無法取得）" : ""
        return "服務正常 · " + names.joined(separator: "、") + rest
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(unknown ? Color.gray : Color.green)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .help(unknown ? "收集器每 5 分鐘讀一次 Anthropic 與 OpenAI 的公開狀態頁；目前沒有 30 分鐘內的結果" : "Anthropic 與 OpenAI 公開狀態頁的結果（收集器每 5 分鐘讀一次）")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// 有異常或額度用完時的卡片內容：每個服務一列，下方說明是服務異常還是額度用完。
struct ServiceStatusCardContent: View {
    let rows: [ServiceStatusRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                ServiceStatusRowView(row: row)
            }
        }
    }
}

struct ServiceStatusRowView: View {
    let row: ServiceStatusRow

    @Environment(\.panelMotion) private var motion

    private var stateText: String {
        switch row.health {
        case .operational: "運作正常"
        case .disrupted(let summary, _): summary
        case .maintenance(let summary): "維護中：\(summary)"
        case .unknown: "無法取得狀態"
        }
    }

    private var dotColor: Color {
        switch row.health {
        case .operational: .green
        case .disrupted: UsageColors.notice
        case .maintenance: .blue
        case .unknown: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color: dotColor, pulse: row.health.isDisruption ? motion.statusPulse : 0)
                ProviderIcon(row.provider)
                    .foregroundStyle(UsageColors.provider(row.provider))
                    .frame(width: 13, height: 13)
                Text(ProviderInfo.displayName(row.provider))
                    .font(.callout.weight(.semibold))
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(stateText)
                Spacer(minLength: 4)
                if row.health.isProblem, let url = ServiceStatusPage.url(row.provider) {
                    // 自己畫（不用 Link），ImageRenderer 才能截圖；在瀏覽器打開，App 本身不連網
                    Button("狀態頁") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("在瀏覽器打開\(ProviderInfo.displayName(row.provider))的狀態頁")
                }
            }
            if case .disrupted(_, true) = row.health {
                Text("可能影響 \(row.provider == "codex" ? "Codex" : "Claude Code")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 13)
            }
            if let explanation = row.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 狀態點：異常時呼吸閃爍 3 次後停止（ADR-0010：3 × 0.8 秒）。`pulse` 為 0…3，整數時靜止。
struct StatusDot: View, Animatable {
    let color: Color
    var pulse: Double

    nonisolated var animatableData: Double {
        get { pulse }
        set { pulse = newValue }
    }

    var body: some View {
        // 每一次呼吸：0→1→0（餘弦），pulse 為整數時完全靜止
        let phase = pulse - pulse.rounded(.down)
        let intensity = pulse > 0 && pulse < 3 ? 0.5 - 0.5 * cos(2 * .pi * phase) : 0
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(1 - 0.55 * intensity)
            .background {
                Circle()
                    .fill(color.opacity(0.35 * intensity))
                    .scaleEffect(1 + 1.2 * intensity)
            }
    }
}

extension ServiceHealth {
    var isDisruption: Bool {
        if case .disrupted = self { true } else { false }
    }
}
