import SwiftUI
import UsageKit
import UsageKitUI

// MARK: - 接下來的重置（FR-40）

struct ResetsCardHeader: View {
    var body: some View {
        HStack {
            PanelCardTitle(text: PanelSection.resets.title)
            Spacer(minLength: 4)
            Text("未來 8 小時").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ResetsCardContent: View {
    let snapshot: UsageSnapshot
    let history: QuotaHistory
    let stale: Bool
    let now: Date

    @Environment(\.panelMotion) private var motion

    var body: some View {
        let resets = UpcomingReset.list(snapshot: snapshot, now: now)
        let waiting = UpcomingReset.awaitingStart(snapshot: snapshot)
        let forecasts = WeeklyForecast.list(snapshot: snapshot, history: history, now: now)
        VStack(alignment: .leading, spacing: 12) {
            ResetTimeline(resets: resets, stale: stale, progress: motion.timeline)
            if !waiting.isEmpty {
                // 服務回報沒有重置時間：已重置，新一輪要等下次使用才開始計時
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(waiting, id: \.key) { item in
                        Text("\(ResetTimeline.name(provider: item.provider, window: item.window))：已重置，下次使用時開始計時")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !forecasts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(forecasts, id: \.provider) { forecast in
                        ForecastLine(forecast: forecast, now: now)
                    }
                }
            }
        }
    }
}

/// 時間軸：左端是「現在」，右端是 8 小時後；每個會重置的額度一個圓點，下方標名稱與時間。
/// `Animatable`：圓點依序出發需要逐格的進度（只改終點的話 SwiftUI 只會把位置線性補間，沒有先後）。
struct ResetTimeline: View, Animatable {
    let resets: [UpcomingReset]
    let stale: Bool
    /// 圓點滑到位置的進度（0→1）
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.panelMotion) private var motion

    private static let labelWidth: CGFloat = 72

    var body: some View {
        if resets.isEmpty && motion.departing.isEmpty {
            HStack(spacing: 6) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 3)
            }
            .overlay(alignment: .leading) {
                Text("未來 8 小時沒有額度重置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                    .offset(y: 14)
            }
            .frame(height: 30, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("未來 8 小時沒有額度重置")
        } else {
            let rows = labelRows()
            GeometryReader { geo in
                let width = geo.size.width - 8
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: geo.size.width, height: 3).offset(y: 6)
                    // 有「剛重置」時它的標籤就在現在的位置，不另外寫「現在」
                    if !showsJustReset {
                        Text("現在").font(.caption2).foregroundStyle(.secondary).offset(y: 18)
                    }
                    ForEach(Array(resets.enumerated()), id: \.offset) { index, reset in
                        let x: CGFloat = 4 + width * CGFloat(reset.position * stagger(index))
                        dot(reset.provider)
                            .position(x: x, y: 7.5)
                        VStack(spacing: 0) {
                            Text(Self.name(reset))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Group {
                                if reset.justReset {
                                    // 重置時間已過、收集器還沒拿到新的重置時間
                                    Text("剛重置")
                                } else {
                                    Text(reset.resetsAt, format: .dateTime.hour().minute())
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        }
                        .lineLimit(1)
                        .frame(width: Self.labelWidth)
                        .position(x: Self.labelX(x, width: geo.size.width), y: 34 + CGFloat(rows[index]) * 30)
                        .opacity(stagger(index))
                    }
                    // 額度重置：該圓點在「現在」的位置放大淡出（服務圖示同時閃光芒）
                    ForEach(motion.departing.keys.sorted(), id: \.self) { key in
                        let progress = motion.departing[key] ?? 1
                        dot(String(key.split(separator: "/").first ?? ""))
                            .scaleEffect(1 + 1.2 * progress)
                            .opacity(1 - progress)
                            .position(x: 4, y: 7.5)
                    }
                }
            }
            .frame(height: 54 + CGFloat(rows.max() ?? 0) * 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var showsJustReset: Bool { resets.contains(where: \.justReset) }

    /// 「Claude 5h」「Codex 每週」
    static func name(_ reset: UpcomingReset) -> String {
        name(provider: reset.provider, window: reset.window)
    }

    static func name(provider: String, window: UsageWindow) -> String {
        window.id == "five_hour" ? "\(ProviderInfo.displayName(provider)) 5h"
            : ProviderWindow(provider: provider, window: window).displayName
    }

    /// 標籤置中在圓點下方，但不超出時間軸兩端
    static func labelX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, labelWidth / 2), width - labelWidth / 2)
    }

    private func dot(_ provider: String) -> some View {
        Circle()
            .fill(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(provider)))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
    }

    /// 圓點依序滑到位置：第 i 個晚 0.08 開始。
    private func stagger(_ index: Int) -> Double {
        let delay = 0.08 * Double(index)
        let span = max(1 - 0.08 * Double(max(resets.count - 1, 0)), 0.4)
        let t = min(max((progress - delay) / span, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    /// 標籤太近時換到下一行（依時間軸寬約 300pt 估計；標籤寬 72pt）。
    private func labelRows() -> [Int] {
        var rows: [Int] = []
        // 第一行最左邊有「現在」（約 28pt）：標籤中心要在 68pt 以後才不會蓋到，否則換行
        var lastX: [Int: Double] = showsJustReset ? [:] : [0: 68 - Double(Self.labelWidth)]
        for reset in resets {
            let x = reset.position * 300
            let row = (0..<4).first { r in lastX[r].map { x - $0 >= Double(Self.labelWidth) } ?? true } ?? 0
            rows.append(row)
            lastX[row] = x
        }
        return rows
    }

    private var accessibilityText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let items = resets.map { reset in
            let name = ProviderWindow(provider: reset.provider, window: reset.window).displayName
            return reset.justReset ? "\(name) 剛重置" : "\(name) \(formatter.string(from: reset.resetsAt)) 重置"
        }
        return "未來 8 小時：" + items.joined(separator: "，")
    }
}

/// 「✶ 每週額度照目前速度可撐到 週五晚上 · 週日 23:00 重置」
struct ForecastLine: View {
    let forecast: WeeklyForecast
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ProviderIcon(forecast.provider)
                .foregroundStyle(UsageColors.provider(forecast.provider))
                .frame(width: 11, height: 11)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Group {
                switch forecast.outcome {
                case let .runsOut(at):
                    Text("每週額度照目前速度可撐到 ") + Text(WeeklyForecast.dayPart(at)).fontWeight(.semibold).foregroundColor(UsageColors.notice)
                case .lastsUntilReset:
                    Text("每週額度照目前速度撐得到重置")
                }
            }
            Text("· \(Self.resetText(forecast.resetsAt))").foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .help(forecast.usesRecentRate ? "依最近 24 小時的速度估計" : "歷史資料還不夠，依本週開始至今的平均速度估計")
        .accessibilityElement(children: .combine)
    }

    static func resetText(_ date: Date) -> String {
        let weekday = WeeklyForecast.dayPart(date).prefix(2)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(weekday) \(formatter.string(from: date)) 重置"
    }
}
