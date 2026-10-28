import SwiftUI
import UsageKit
import UsageKitUI

/// 瀏海面板的畫面（MASCOT-SPEC 第 3 節）：固定 580×190 的畫布，以 `NotchShape` 遮罩顯示目前的大小。
/// 收合時是瀏海大小：左邊迷你角色、右邊服務色的迷你圓環與百分比；展開時上緣放分頁與更新時間，
/// 下方左邊是角色卡、右邊是 Claude 與 Codex 的額度卡。
struct NotchView: View {
    @Environment(MascotController.self) private var controller
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings

    /// 截圖用：固定的時間（毫秒）；nil 表示依時鐘
    var fixedTime: Int?

    var body: some View {
        if let director = controller.director {
            if let fixedTime {
                NotchCanvas(director: director, time: fixedTime, layout: controller.layout, snapshot: store.snapshot,
                            now: store.now, character: settings.mascotCharacter)
            } else {
                let rate = controller.renderRate
                TimelineView(.animation(minimumInterval: rate.interval, paused: rate == .stopped)) { context in
                    NotchCanvas(director: director, time: controller.time(context.date), layout: controller.layout,
                                snapshot: store.snapshot, now: store.now, character: settings.mascotCharacter,
                                motion: controller.motion)
                }
            }
        }
    }
}

/// 瀏海的形狀：上緣貼齊螢幕頂端、下方兩角圓角
struct NotchShape: Shape {
    var width: Double
    var height: Double
    var corner: Double

    func path(in rect: CGRect) -> Path {
        let x0 = rect.midX - width / 2, x1 = rect.midX + width / 2
        let r = min(corner, height / 2, width / 2)
        var path = Path()
        path.move(to: CGPoint(x: x0, y: 0))
        path.addLine(to: CGPoint(x: x1, y: 0))
        path.addLine(to: CGPoint(x: x1, y: height - r))
        path.addQuadCurve(to: CGPoint(x: x1 - r, y: height), control: CGPoint(x: x1, y: height))
        path.addLine(to: CGPoint(x: x0 + r, y: height))
        path.addQuadCurve(to: CGPoint(x: x0, y: height - r), control: CGPoint(x: x0, y: height))
        path.closeSubpath()
        return path
    }
}

/// 某一刻的整個瀏海（純函式：director＋時間）
struct NotchCanvas: View {
    let director: MascotDirector
    let time: Int
    let layout: NotchLayout
    let snapshot: UsageSnapshot?
    let now: Date
    let character: MascotCharacter
    /// 截圖用：看滑鼠的方向固定為正面
    var gazeOverride: (yaw: Double, pitch: Double)?
    /// 動畫程度：簡單時不畫粒子與光環；關閉時也不眨眼、不看滑鼠
    var motion = MascotMotionLevel.full

    var body: some View {
        let shape = director.panelShape(at: time)
        let content = director.content(at: time)
        ZStack(alignment: .topLeading) {
            NotchShape(width: shape.width, height: shape.height, corner: shape.corner).fill(.black)
            NotchContent(snapshot: snapshot, now: now)
                .opacity(content.opacity)
                .offset(y: content.offset)
            miniRing
                .opacity(shape.miniOpacity)
            Canvas(rendersAsynchronously: false) { context, _ in
                MascotPainter(config: director.config).draw(frame, in: &context, particles: motion.drawsParticles)
            }
            .allowsHitTesting(false)
        }
        .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
        .mask(NotchShape(width: shape.width, height: shape.height, corner: shape.corner))
        .accessibilityElement(children: .contain)
    }

    private var frame: MascotFrame {
        let still = !motion.reacts
        let gaze = gazeOverride ?? (still ? (0, 0) : director.gaze(at: time))
        return MascotFrame(time: time, pose: director.pose(at: time), eyes: director.eyes(at: time),
                           blink: still ? 0 : director.blink(at: time),
                           gazeYaw: gaze.yaw, gazePitch: gaze.pitch, statusColor: director.statusColor(at: time),
                           sleeping: director.mode == .sleep && director.machine.isOpen, effects: director.effects,
                           ripple: director.ripple, character: character)
    }

    /// 收合時右邊：服務色的迷你圓環與剩餘百分比（角色所代表的服務中剩最少的額度）
    @ViewBuilder
    private var miniRing: some View {
        let item = snapshot.flatMap { NotchQuota.tightest(in: $0, provider: character.provider, now: now) }
        let remaining = item.map { Int($0.effectiveRemainingPct(at: now).rounded()) }
        let stale = snapshot?.isStale(now: now) ?? false
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 2.2, dash: stale ? [1.8, 1.6] : []))
                Circle()
                    .trim(from: 0, to: Double(remaining ?? 0) / 100)
                    .stroke(ringColor(item), style: StrokeStyle(lineWidth: 2.2, lineCap: stale ? .butt : .round, dash: stale ? [1.8, 1.6] : []))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(remaining.map { "\($0)%" } ?? "–")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .frame(width: 44, alignment: .leading)
        .position(x: layout.ringX - 6.5 + 22, y: layout.miniY)
        .accessibilityLabel("\(character.title) 剩 \(remaining.map(String.init) ?? "–")%\(stale ? "，資料已過期" : "")")
    }

    /// 迷你圓環的顏色：同選單列圖示（過期灰、剩不到 20% 紅、其他服務色）；過期時另改成虛線，不只靠顏色
    private func ringColor(_ item: UsageWindow?) -> Color {
        guard let item, let snapshot else { return UsageColors.provider(character.provider) }
        return UsageColors.bar(item, provider: character.provider, stale: snapshot.isStale(now: now), now: now)
    }
}

/// 額度的挑選（瀏海面板用）
enum NotchQuota {
    /// 某服務剩最少的額度；服務出錯或沒有資料為 nil
    static func tightest(in snapshot: UsageSnapshot, provider: String, now: Date) -> UsageWindow? {
        guard let usage = snapshot.providers[provider], usage.error == nil else { return nil }
        return usage.visibleWindows.min { $0.effectiveRemainingPct(at: now) < $1.effectiveRemainingPct(at: now) }
    }

    /// 狀態點的等級：出錯或用完 2、剩不到 20% 1、其他 0（同通知「剩不到 20%」的門檻）
    static func statusLevel(in snapshot: UsageSnapshot?, provider: String, now: Date) -> Int {
        guard let snapshot, let usage = snapshot.providers[provider] else { return 0 }
        if usage.error != nil { return 2 }
        guard let window = tightest(in: snapshot, provider: provider, now: now) else { return 0 }
        let remaining = window.effectiveRemainingPct(at: now)
        if remaining <= 0 { return 2 }
        return remaining < UsageSeverity.criticalBelow ? 1 : 0
    }
}

/// 展開後的內容：上緣分頁與更新時間、角色卡（角色由畫布畫在上面）、額度卡
struct NotchContent: View {
    let snapshot: UsageSnapshot?
    let now: Date

    private static let card = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255)
    private static let secondary = Color(red: 0x9a / 255, green: 0x9a / 255, blue: 0xa8 / 255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                NotchTab(symbol: "house.fill", label: "總覽", selected: true) {}
                NotchTab(symbol: "clock", label: "歷史") { AppActions.openStats?(); NSApplication.shared.activate() }
                NotchTab(symbol: "gearshape", label: "設定") { AppActions.openSettings?(); NSApplication.shared.activate() }
            }
            .frame(height: 20)
            .position(x: 20 + 42, y: 17)
            updated
                .frame(height: 20)
                .position(x: NotchLayout.canvasWidth - 20 - 50, y: 17)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 18).fill(Self.card)
                    .frame(width: 140)
                    .accessibilityHidden(true)
                quotaCard
            }
            .padding(EdgeInsets(top: 34, leading: 16, bottom: 14 + 10, trailing: 16))
            .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
        }
        .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight, alignment: .topLeading)
    }

    private var updated: some View {
        HStack(spacing: 6) {
            if let snapshot {
                Text(ResetCountdown.updatedText(since: snapshot.updatedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0x8d / 255, green: 0x8d / 255, blue: 0x9a / 255))
                Circle()
                    .fill(snapshot.isStale(now: now) ? Color.gray : Color(red: 63 / 255, green: 208 / 255, blue: 122 / 255))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(snapshot.isStale(now: now) ? "資料過期" : "連線正常")
            }
        }
        .fixedSize()
    }

    private var quotaCard: some View {
        HStack(alignment: .top, spacing: 18) {
            column("claude")
            column("codex")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Self.card))
    }

    @ViewBuilder
    private func column(_ provider: String) -> some View {
        let usage = snapshot?.providers[provider]
        let tint = UsageColors.provider(provider)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(ProviderInfo.displayName(provider))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xee / 255))
            }
            .padding(.bottom, 2)
            if let usage, usage.error == nil {
                let windows = usage.visibleWindows
                let stale = snapshot?.isStale(now: now) ?? false
                ForEach(Array(windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                    // 同面板的進度條規則（FR-16）：過期灰、剩不到 20% 紅、其他服務色
                    row(window, tint: UsageColors.bar(window, provider: provider, stale: stale, now: now), primary: index == 0)
                }
                if let reset = windows.first?.resetsAt, let text = ResetCountdown.text(until: reset, now: now) {
                    Text("\(text)後重置")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0x6f / 255, green: 0x6f / 255, blue: 0x7d / 255))
                        .padding(.top, 7)
                }
            } else {
                Text(usage == nil ? "沒有啟用" : "讀取失敗")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.secondary)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ window: UsageWindow, tint: Color, primary: Bool) -> some View {
        let remaining = window.effectiveRemainingPct(at: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).foregroundStyle(Self.secondary)
                Spacer()
                Text("剩 \(Int(remaining.rounded()))%")
                    .fontWeight(.medium)
                    .foregroundStyle(Color(red: 0xd6 / 255, green: 0xd6 / 255, blue: 0xe0 / 255))
            }
            .font(.system(size: 11).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0x2a / 255, green: 0x2a / 255, blue: 0x32 / 255))
                    Capsule().fill(tint.opacity(primary ? 1 : 0.6))
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.top, 7)
    }
}

/// 上緣的分頁按鈕（總覽在瀏海裡；歷史、設定打開現有的視窗）
struct NotchTab: View {
    let symbol: String
    let label: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 20)
                .background(Capsule().fill(selected ? Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2e / 255) : .clear))
                .foregroundStyle(selected ? Color(red: 0xe8 / 255, green: 0xe8 / 255, blue: 0xf0 / 255)
                                          : Color(red: 0x77 / 255, green: 0x77 / 255, blue: 0x8a / 255))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
