import SwiftUI
import UsageKit
import UsageKitUI

/// 點開選單列後的面板（FR-22、FR-34）：單一長版、卡片式，區塊依設定排序與開關（FR-35）。
/// 保留原本面板的所有資訊：最吃緊的一項、所有額度、方案、重置倒數或已重置、服務錯誤、
/// 沒有服務的提示、更新時間與資料過期、讀檔錯誤與路徑、結束按鈕。
struct PanelView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings

    /// Debug 截圖工具直接指定動畫進度；一般執行時為 nil，由面板自己驅動
    var fixedMotion: PanelMotion?
    /// ImageRenderer 畫不出 AppKit 的捲動視圖，截圖時關掉捲動
    var scrolls = true

    @State private var motion = PanelMotion.settled
    @State private var visible = false
    @State private var refreshHint = false
    @State private var resetSignature: [String: [String: Date]] = [:]
    /// 面板關閉時加一，讓關閉前排定的動畫完成回呼失效（NFR-8）
    @State private var motionGeneration = 0

    private var animates: Bool { visible && !reduceMotion && fixedMotion == nil }

    var body: some View {
        if scrolls {
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 360)
                .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 40)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(behavior)
        } else {
            content.frame(width: 360).modifier(behavior)
        }
    }

    private var behavior: PanelBehavior {
        PanelBehavior(
            motion: fixedMotion ?? motion, animates: animates, live: visible || fixedMotion != nil, colorScheme: colorScheme,
            visible: $visible, onVisibleChange: { $0 ? playAppear() : stopAnimations() },
            snapshot: store.snapshot, now: store.now,
            onSnapshotChange: { detectResets(old: $0, new: $1) },
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
                    }
                    if sections.isEmpty {
                        allHidden
                    }
                }
                footer
            }
            .padding(16)
    }

    /// Debug 的效能量測腳本用來觸發動畫（Release 不含）
    private func debugAction(_ action: String) {
        #if DEBUG
        switch action {
        case "refresh": refresh()
        case "glow": if animates { playGlow(store.snapshot?.tightestWindow(at: store.now)?.provider ?? "claude") }
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
                PanelCard(id: section.rawValue, title: section.title, collapsed: collapsed) {
                    RingCardContent(item: item, stale: stale, now: store.now)
                }
            }
        case .quota:
            PanelCard(id: section.rawValue, title: section.title, collapsed: collapsed) {
                QuotaCardContent(snapshot: snapshot, stale: stale, now: store.now, showsMarker: settings.showsExpectedMarker)
            }
        }
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
        if refreshHint {
            Text("資料沒有變化；收集器每 5 分鐘更新一次")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func refresh() {
        let before = store.snapshot?.updatedAt
        store.reload()
        let unchanged = store.snapshot?.updatedAt == before && store.errorMessage == nil
        guard animates else {
            refreshHint = unchanged
            return
        }
        let generation = motionGeneration
        withAnimation(PanelTiming.refreshSpin) {
            motion.refreshTurns += 1
        } completion: {
            // 旋轉途中關閉面板時不再接著閃狀態點
            guard generation == motionGeneration else { return }
            withAnimation(PanelTiming.dotFlash) { motion.dotFlash = 1 } completion: { motion.dotFlash = 0 }
        }
        withAnimation(PanelTiming.reducedFade) { refreshHint = unchanged }
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
    }

    /// 面板關閉：停止所有動畫並回到靜止狀態，關閉期間不播放任何東西（NFR-8）。
    private func stopAnimations() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        motionGeneration += 1
        withTransaction(transaction) {
            motion = .settled
            refreshHint = false
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
            let didReset = windows.contains { id, resetsAt in
                guard let before = previous[id] else { return false }
                return resetsAt > before
            }
            if didReset { playGlow(provider) }
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
    let onSnapshotChange: (UsageSnapshot?, UsageSnapshot?) -> Void
    let onDebugAction: (String) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.panelMotion, motion)
            .environment(\.panelAnimates, animates)
            .environment(\.panelLive, live)
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
