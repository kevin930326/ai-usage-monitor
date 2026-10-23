import AppKit
import SwiftUI

// 面板動畫的共用元件（FR-25、ADR-0010）。
// 規則：只在面板開啟時執行；「減少動態效果」時直接顯示；一次性、有終點，不循環。
// 每個動畫都以一個 0...1 的進度值表示，正常執行時由 withAnimation 驅動，
// Debug 截圖工具則直接指定每一格的進度，用同一套畫面輸出 PNG 序列（ADR-0010 第 4 節）。

/// 面板目前的動畫進度。
struct PanelMotion: Equatable {
    /// 打開面板時圓環與用量條從 0 長到目前位置
    var appear: Double = 1
    /// 預期進度標記淡入（比 appear 晚一點）
    var marker: Double = 1
    /// 更新按鈕轉過的圈數
    var refreshTurns: Double = 0
    /// 更新完成後狀態點閃一下，0→1 播放一次
    var dotFlash: Double = 0
    /// 額度重置時服務圖示的光芒，0→1 播放一次（依服務）
    var glow: [String: Double] = [:]
    /// 只給 Debug 截圖用：指定卡片收合的進度（1＝展開、0＝收合），一般執行時由卡片自己的狀態決定
    var reveal: [String: Double] = [:]
    /// 走勢曲線由左往右描繪，最後的圓點輕彈一下（第二階段）
    var trend: Double = 1
    /// 「建議接下來用」從上方滑入
    var suggest: Double = 1
    /// 重置時間軸的圓點依序滑到位置
    var timeline: Double = 1
    /// 額度重置時，時間軸上該圓點在「現在」的位置放大淡出，0→1 播放一次（依「服務/額度 id」）
    var departing: [String: Double] = [:]
    /// 骨架畫面的掃光：0→3 掃三次（整數時光在畫面外）
    var shimmer: Double = 0

    static let settled = PanelMotion()

    /// 打開面板時的起點：圓環、用量條、標記、走勢、建議、時間軸都從 0 開始
    static let hidden = PanelMotion(appear: 0, marker: 0, trend: 0, suggest: 0, timeline: 0)
}

/// 各動畫的長度與曲線，集中在這裡方便量測與調整（ADR-0010 第 2 節）。
enum PanelTiming {
    static let appear = Animation.easeOut(duration: 0.6)
    static let marker = Animation.easeOut(duration: 0.2).delay(0.45)
    static let barUpdate = Animation.easeInOut(duration: 0.5)
    static let refreshSpin = Animation.easeInOut(duration: 0.6)
    static let dotFlash = Animation.linear(duration: 0.5)
    static let glow = Animation.linear(duration: 0.8)
    static let collapse = Animation.easeInOut(duration: 0.25)
    static let colorScheme = Animation.easeInOut(duration: 0.3)
    static let trend = Animation.easeOut(duration: 0.6)
    static let suggest = Animation.easeOut(duration: 0.3)
    static let timeline = Animation.easeOut(duration: 0.5)
    static let departing = Animation.easeOut(duration: 0.5)
    /// 骨架掃光：每次 1.2 秒、三次（ADR-0010：重複類最多 3 次、總長 ≤ 4 秒）
    static let shimmerPasses = 3.0
    static let shimmer = Animation.linear(duration: 1.2 * shimmerPasses)
    /// 切換額度時新舊曲線交叉淡入
    static let crossfade = Animation.easeInOut(duration: 0.3)
    /// 「減少動態效果」時只允許短暫淡入淡出
    static let reducedFade = Animation.easeInOut(duration: 0.15)
}

private struct PanelMotionKey: EnvironmentKey {
    static let defaultValue = PanelMotion.settled
}

private struct PanelAnimatesKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PanelLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelMotion: PanelMotion {
        get { self[PanelMotionKey.self] }
        set { self[PanelMotionKey.self] = newValue }
    }

    /// 面板開啟且沒有開啟「減少動態效果」時為真；資料更新時的轉場依這個值決定要不要動
    var panelAnimates: Bool {
        get { self[PanelAnimatesKey.self] }
        set { self[PanelAnimatesKey.self] = newValue }
    }

    /// 面板看得見（或在截圖）時為真。選單列面板關閉時視窗只是被收起、視圖仍在，
    /// 會自動更新的相對時間文字（`Text(date, style: .relative)`）會繼續定時重算，
    /// 所以關閉時改為不會更新的文字（NFR-8）
    var panelLive: Bool {
        get { self[PanelLiveKey.self] }
        set { self[PanelLiveKey.self] = newValue }
    }
}

/// 相對時間（「1 小時 34 分鐘」）：面板開啟時由系統自動倒數，關閉時換成固定的空字串，不再定時重算。
struct LiveRelativeText: View {
    let date: Date
    @Environment(\.panelLive) private var live

    var body: some View {
        if live {
            Text(date, style: .relative)
        } else {
            Text(verbatim: "")
        }
    }
}

/// 百分比數字：值改變時逐步滾動（動畫中每一格都重算顯示的整數）。
struct RollingPercent: View, Animatable {
    var value: Double
    var font: Font

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(font)
            .monospacedDigit()
    }
}

/// 一次性的光芒：進度 0→1 之間亮起再消失（sin 曲線），0 與 1 時完全看不到。
struct GlowEffect: ViewModifier, Animatable {
    var progress: Double
    var color: Color

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let intensity = progress > 0 && progress < 1 ? sin(.pi * progress) : 0
        content
            .scaleEffect(1 + 0.35 * intensity)
            .shadow(color: color.opacity(0.9 * intensity), radius: 8 * intensity)
            .background {
                Circle()
                    .fill(color.opacity(0.35 * intensity))
                    .scaleEffect(0.6 + 1.4 * progress)
                    .blur(radius: 3)
            }
    }
}

/// 一次性的閃光：進度 0→1 之間放大再縮回。
struct FlashEffect: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let intensity = progress > 0 && progress < 1 ? sin(.pi * progress) : 0
        content
            .scaleEffect(1 + 0.8 * intensity)
            .opacity(1 - 0.3 * intensity)
    }
}

/// 卡片收合：只顯示內容高度的 `progress` 比例（從上往下裁切），下方卡片因此順勢上移。
struct VerticalReveal: Layout {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) ?? .zero
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// 回報承載這個視圖的視窗是否看得見（選單列面板關閉時視窗會被收起，occlusion 變成不可見）。
/// 用來確保動畫只在面板開啟時執行（NFR-8）。
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        // deinit 不在 main actor 上；只在 main actor 修改，deinit 時已沒有其他存取
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if closing {
                            self.report(false)
                        } else {
                            self.reportCurrent()
                        }
                    }
                }
            }
            reportCurrent()
        }

        private func reportCurrent() {
            guard let window else { return report(false) }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
