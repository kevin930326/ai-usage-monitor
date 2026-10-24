import SwiftUI
import UsageKit
import UsageKitUI

// 面板第二階段的區塊（FR-39～FR-42、FR-46，ADR-0008 第 2 節）共用的部分：額度歷史的環境值、選擇額度、
// 骨架畫面與斜線。各卡片在 SuggestBanner.swift、ResetsCard.swift、TrendCard.swift、ConsumptionCard.swift。
// 計算都在 UsageKit（QuotaHistory.swift），這裡只負責畫。
// 文字一律 primary／secondary，顏色只用在服務圖示、曲線、熱力圖與提示文字（設計 skill 第 1 節）。

private struct QuotaHistoryKey: EnvironmentKey {
    static let defaultValue = QuotaHistory.empty
}

extension EnvironmentValues {
    /// 面板開啟時讀到的額度歷史；用量節奏的「約 N 分鐘後用完」改用近期速度（ADR-0008 第 4 節）
    var quotaHistory: QuotaHistory {
        get { self[QuotaHistoryKey.self] }
        set { self[QuotaHistoryKey.self] = newValue }
    }
}

// MARK: - 選擇額度

/// 走勢與額度消耗可切換的額度：沒有錯誤的服務中，長度已知的可見額度。
struct HistoryWindowOption: Identifiable, Equatable {
    var provider: String
    var window: UsageWindow
    var id: String { "\(provider)/\(window.id)" }

    var item: ProviderWindow { ProviderWindow(provider: provider, window: window) }

    /// 標籤上的短名稱（圖示已表示服務）：「每週」「5h」
    var shortLabel: String { window.id == "five_hour" ? "5h" : window.label }

    static func options(_ snapshot: UsageSnapshot) -> [HistoryWindowOption] {
        snapshot.orderedProviderKeys.flatMap { key -> [HistoryWindowOption] in
            guard let p = snapshot.providers[key], p.error == nil else { return [] }
            return p.visibleWindows.filter { $0.duration != nil }.map { HistoryWindowOption(provider: key, window: $0) }
        }
    }

    /// 儲存的選擇還在就用它，否則用第一個服務的每週額度（都沒有時用第一個）。
    static func resolve(_ stored: String?, in options: [HistoryWindowOption]) -> HistoryWindowOption? {
        if let stored, let match = options.first(where: { $0.id == stored }) { return match }
        return options.first { $0.window.id == "weekly" } ?? options.first
    }
}

struct HistoryWindowChips: View {
    let options: [HistoryWindowOption]
    let selected: HistoryWindowOption
    let stale: Bool
    let select: (HistoryWindowOption) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { select(option) } label: {
                    HStack(spacing: 3) {
                        ProviderIcon(option.provider)
                            .foregroundStyle(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(option.provider)))
                            .frame(width: 10, height: 10)
                        Text(option.shortLabel)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(option == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.item.displayName)
                .accessibilityAddTraits(option == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 骨架畫面（FR-46）

/// 歷史不足時的骨架：灰色的佔位形狀＋說明；打開面板時一道光由左往右掃過（最多 3 次）。
struct HistorySkeleton: View {
    let status: HistoryStore.Status
    var height: CGFloat = 96

    @Environment(\.panelMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
                SkeletonCurve()
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(12)
            }
            .frame(height: height)
            .overlay { ShimmerOverlay(progress: motion.shimmer) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private var message: String {
        switch status {
        case .olderSchema: "收集器的版本較舊，請重新執行 collector/scripts/install-launchd.sh"
        case .failed: "無法讀取額度歷史（history.sqlite3）"
        default: "正在收集，幾小時後開始會有資料"
        }
    }

}

/// 骨架的掃光：進度 0→3 掃三次（整數時光在畫面外）。`Animatable` 讓每一格都拿到中間的進度，
/// 否則 0 和 3 的小數部分都是 0，掃光不會出現。
struct ShimmerOverlay: View, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let phase = progress - floor(progress)
        if phase > 0 {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.primary.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: (phase * 1.4 - 0.4) * geo.size.width)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct SkeletonCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.55),
                   control1: CGPoint(x: rect.width * 0.35, y: rect.minY + rect.height * 0.15),
                   control2: CGPoint(x: rect.width * 0.65, y: rect.minY + rect.height * 0.6))
        return p
    }
}

/// 斜線（沒有紀錄的時段）
func drawHatch(_ context: inout GraphicsContext, in rect: CGRect, color: Color, spacing: CGFloat = 5) {
    guard rect.width > 0, rect.height > 0 else { return }
    var path = Path()
    var x = rect.minX - rect.height
    while x < rect.maxX {
        path.move(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        x += spacing
    }
    var clipped = context
    clipped.clip(to: Path(rect))
    clipped.stroke(path, with: .color(color), lineWidth: 1)
}

// MARK: - 斜線圖例

struct HatchSwatch: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                drawHatch(&context, in: CGRect(origin: .zero, size: size), color: .secondary, spacing: 3)
            }
            .frame(width: 9, height: 9)
            Text(label)
        }
    }
}
