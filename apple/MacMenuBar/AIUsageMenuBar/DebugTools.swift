#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UsageKit
import UsageKitUI

/// 開發用（只在 Debug 版本）：
/// - `AUM_DEMO_PANEL=1`：把面板放進一般視窗。MenuBarExtra 無法以程式點開，截圖與量測用這個視窗。
/// - `AUM_RENDER_DIR=<資料夾>`：用 ImageRenderer 輸出面板、選單列圖示與設定視窗的 PNG（淺色、深色）。
/// - `AUM_RENDER_FRAMES=1`（搭配 `AUM_RENDER_DIR`）：每個動畫以 30 fps 輸出 PNG 序列並組成 GIF。
/// - `AUM_RENDER_NAME=<名稱>`：面板 PNG 的檔名前綴（預設 `panel`），換一份假歷史再輸出一次時用。
/// - `AUM_RENDER_ANIMS=<名稱,名稱>`：只輸出這些動畫（預設全部）。
/// - `AUM_RENDER_EXIT=1`：輸出完就結束。
/// - `AUM_RENDER_NOW=<ISO 8601>`：畫面的「現在」固定成這個時間（`RenderClock`，截圖比對用，見 `scripts/snapshots.sh`）。
/// - `AUM_DEMO_PERF=1`（搭配 `AUM_DEMO_PANEL=1`）：依固定時間表打開面板、觸發動畫、關閉、再開關一次，給 `scripts/measure-panel-perf.sh` 量測。
@MainActor
enum DebugTools {
    private static var panelWindow: NSWindow?
    private static var statsWindow: NSWindow?

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        // 量測時先記錄面板開啟前的基準，10 秒後才打開
        if env["AUM_DEMO_PANEL"] == "1", env["AUM_DEMO_PERF"] != "1" { showPanelWindow() }
        if let dir = env["AUM_RENDER_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // 面板關著時不讀資料庫；截圖時沒有「打開面板」，所以先讀一次
            HistoryStore.shared.open()
            let name = env["AUM_RENDER_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "panel"
            renderPanel(to: url, name: name)
            if name == "panel" {
                renderMenuBarIcons(to: url)
                renderSettings(to: url)
                renderStats(to: url)
                renderStatus(to: url)
            }
            let only = env["AUM_RENDER_ANIMS"].map { Set($0.split(separator: ",").map(String.init)) }
            if env["AUM_RENDER_FRAMES"] == "1" { renderAnimations(to: url, only: only) }
            if env["AUM_RENDER_EXIT"] == "1" { exit(0) }
        }
        if env["AUM_DEMO_PERF"] == "1" { runPerfSchedule() }
    }

    private static func showPanelWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI 用量（面板預覽）"
        window.contentView = NSHostingView(rootView: PanelView().environment(UsageStore.shared).environment(PanelSettings.shared).environment(HistoryStore.shared))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        panelWindow = window
        UsageStore.log("demo panel window \(window.windowNumber)")
    }

    /// 量測用：以一般視窗打開完整統計（與 Window scene 相同的視圖；關閉時釋放視窗與資料）
    private static func showStatsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "完整統計"
        window.contentView = NSHostingView(rootView: StatsWindowView(historyStore: HistoryStore.shared))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        statsWindow = window
    }

    // MARK: - 效能量測的時間表（ADR-0010 第 3 節）

    /// 每個步驟在 stderr 印出 `perf-mark <秒> <名稱>`，量測腳本依此把 ps 的取樣分段。
    private static func runPerfSchedule() {
        let close = 64.0
        let steps: [(TimeInterval, String, @MainActor () -> Void)] = [
            (0, "launch", {}),
            (10, "panel-open", { showPanelWindow() }),
            (22, "refresh", { DebugAction.send("refresh") }),
            (27, "glow", { DebugAction.send("glow") }),
            (32, "collapse", { DebugAction.send("collapse") }),
            (35, "expand", { DebugAction.send("expand") }),
            (38, "trend-next", { DebugAction.send("trend-next") }),
            (41, "departing", { DebugAction.send("departing") }),
            (44, "appearance-dark", { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }),
            (48, "appearance-light", { NSApplication.shared.appearance = nil }),
            // 第三階段：捲到統計卡片，切換服務（長條與熱力圖重新長出、數字滾動）、切換 Token 活動範圍
            (50, "stats-scroll", { DebugAction.send("stats-scroll") }),
            (51, "stats-scope", { DebugAction.send("stats-scope") }),
            (54, "stats-range", { DebugAction.send("stats-range") }),
            // 第四階段：捲到服務狀態，異常的橘點呼吸 3 次；點通知時額度卡片亮一下
            (57, "status-pulse", { DebugAction.send("status-pulse") }),
            (61, "highlight", { DebugAction.send("highlight") }),
            (close, "panel-close", { panelWindow?.orderOut(nil) }),
            (close + 60, "closed-60s", {}),
            (close + 90, "closed-90s", {}),
            // 第二次開關：比較兩次關閉後的記憶體，確認沒有累積（第一次開啟會載入框架，不能和開啟前比）
            (close + 92, "panel-reopen", { panelWindow?.makeKeyAndOrderFront(nil) }),
            (close + 100, "panel-close-2", { panelWindow?.orderOut(nil) }),
            // 完整統計視窗：打開 10 秒後關閉，關閉後資料應釋放
            (close + 120, "stats-open", { showStatsWindow() }),
            (close + 130, "stats-close", { statsWindow?.close(); statsWindow?.contentView = nil; statsWindow = nil }),
            (close + 150, "exit", { exit(0) }),
        ]
        let start = Date.now
        for (offset, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                MainActor.assumeIsolated {
                    action()
                    UsageStore.log(String(format: "perf-mark %.1f %@", Date.now.timeIntervalSince(start), name))
                }
            }
        }
    }

    // MARK: - 靜態截圖

    private static var snapshot: UsageSnapshot { UsageStore.shared.snapshot ?? sample() }

    /// 還沒讀到 usage.json 時截圖用的範例資料
    private static func sample(now: Date = RenderClock.now) -> UsageSnapshot {
        UsageSnapshot(updatedAt: now.addingTimeInterval(-120), providers: [
            "claude": ProviderUsage(plan: "Max", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 62, resetsAt: now.addingTimeInterval(6000)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 35, resetsAt: now.addingTimeInterval(3 * 86400)),
            ]),
            "codex": ProviderUsage(plan: "Team", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 12, resetsAt: now.addingTimeInterval(14400)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 48, resetsAt: now.addingTimeInterval(5 * 86400)),
            ]),
        ])
    }

    private static func panel(_ motion: PanelMotion = .settled) -> some View {
        PanelView(fixedMotion: motion, scrolls: false)
            .environment(UsageStore.shared)
            .environment(PanelSettings.shared)
            .environment(HistoryStore.shared)
    }

    private static func renderPanel(to dir: URL, name: String) {
        for scheme in [ColorScheme.light, .dark] {
            write(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: scheme,
                  to: dir.appendingPathComponent("\(name)-\(scheme.name).png"))
            guard name == "panel" else { continue }
            var collapsed = PanelMotion.settled
            collapsed.reveal = [PanelSection.ring.rawValue: 0]
            write(panel(collapsed).background(Color(nsColor: .windowBackgroundColor)), scheme: scheme,
                  to: dir.appendingPathComponent("panel-collapsed-\(scheme.name).png"))
        }
    }

    // MARK: - 統計卡片與完整統計視窗（第三階段）

    /// 統計卡片單獨輸出（面板寬度），方便比較各種狀態
    private static func statsCard(_ data: TokenStatsData, status: HistoryStore.Status = .ready, device: TokenDeviceScope? = nil,
                                  scope: TokenScope = .all, range: TokenActivityRange = .days30, motion: PanelMotion = .settled) -> some View {
        let device = data.devices.resolve(device)
        return PanelCard(id: PanelSection.stats.rawValue, accessibilityTitle: PanelSection.stats.title, collapsed: .constant(false)) {
            StatsCardHeader(devices: data.devices, scope: device, now: RenderClock.now)
        } content: {
            StatsCardContent(data: data, status: status, device: device, scope: scope, range: range, now: RenderClock.now,
                             selectScope: { _ in }, selectRange: { _ in })
        }
        .frame(width: 328)
        .padding(16)
        .environment(\.panelMotion, motion)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func renderStats(to dir: URL) {
        let data = HistoryStore.shared.tokens
        var fresh = TokenStatsData.empty
        fresh.firstScanProgress = 37
        var none = TokenStatsData.empty
        none.firstScanDone = true
        // 保留 7 天：較早的每日資料已刪除，熱力圖與長條不畫成「沒有使用」
        var short = data
        short.retentionDays = 7
        let cutoff = short.firstAvailableDay(now: RenderClock.now).map { TokenCalendar.key($0, calendar: .current) } ?? ""
        short.days.removeAll { $0.day < cutoff }
        for scheme in [ColorScheme.light, .dark] {
            let n = scheme.name
            write(statsCard(data), scheme: scheme, to: dir.appendingPathComponent("stats-card-\(n).png"))
            write(statsCard(data, scope: .codex, range: .weeks), scheme: scheme, to: dir.appendingPathComponent("stats-card-codex-weeks-\(n).png"))
            write(statsCard(data, scope: .claude, range: .cumulative), scheme: scheme, to: dir.appendingPathComponent("stats-card-claude-cumulative-\(n).png"))
            write(statsCard(short, range: .cumulative), scheme: scheme, to: dir.appendingPathComponent("stats-card-retention7-\(n).png"))
            write(statsCard(fresh), scheme: scheme, to: dir.appendingPathComponent("stats-skeleton-\(n).png"))
            write(statsCard(none), scheme: scheme, to: dir.appendingPathComponent("stats-empty-\(n).png"))
            var suspect = data
            suspect.formatSuspect = true
            suspect.skippedLines = 42
            write(statsCard(suspect), scheme: scheme, to: dir.appendingPathComponent("stats-format-suspect-\(n).png"))
            // 所有紀錄都認不得：沒有任何 Token，也要看得到提示
            var suspectEmpty = none
            suspectEmpty.formatSuspect = true
            write(statsCard(suspectEmpty), scheme: scheme, to: dir.appendingPathComponent("stats-format-suspect-empty-\(n).png"))
            write(StatsWindowView(historyStore: HistoryStore.shared, fixedData: suspectEmpty, fixedMotion: .settled, scrolls: false)
                .frame(width: 860, height: 520), scheme: scheme, to: dir.appendingPathComponent("stats-window-format-suspect-empty-\(n).png"))
            write(statsCard(data, status: .olderSchema(1)), scheme: scheme, to: dir.appendingPathComponent("stats-older-schema-\(n).png"))
            if let full = HistoryStore.shared.loadFullTokenStats() {
                write(StatsWindowView(historyStore: HistoryStore.shared, fixedData: full, fixedMotion: .settled, scrolls: false).frame(width: 860),
                      scheme: scheme, to: dir.appendingPathComponent("stats-window-\(n).png"))
            }
        }
        renderTier2(data, to: dir)
    }

    // MARK: - 第二層：多裝置（ADR-0011 第 4 節）

    /// 截圖用的兩台假電腦：本機每日資料的 60%（工作 PC）與 15%（筆電，3 天沒有上傳）
    private static func tier2Sample(_ local: TokenStatsData, revoked: Bool = false) -> TokenStatsData {
        let now = RenderClock.now
        let pc = "0f8e2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b"
        let laptop = "1a2b3c4d-1b2d-4e5f-8a9b-0c1d2e3f4a5b"
        let stale = TokenCalendar.key(now.addingTimeInterval(-3 * 86400), calendar: .current)
        var data = local
        let localRows = local.days.filter { $0.device == TokenDevices.local }
        for (id, share) in [(pc, 0.6), (laptop, 0.15)] {
            for row in localRows where id == pc || row.day <= stale {
                var copy = row
                copy.device = id
                copy.counts = TokenCounts(input: Int64(Double(row.counts.input) * share), cacheWrite: Int64(Double(row.counts.cacheWrite) * share),
                                          cacheRead: Int64(Double(row.counts.cacheRead) * share), output: Int64(Double(row.counts.output) * share),
                                          reasoning: Int64(Double(row.counts.reasoning) * share))
                copy.taskSeconds = Int(Double(row.taskSeconds) * share)
                copy.longestTaskSeconds = Int(Double(row.longestTaskSeconds) * share)
                data.days.append(copy)
            }
        }
        data.devices = TokenDevices(devices: [
            TokenDevice(id: "self-id", name: "Mac", lastUpload: now.addingTimeInterval(-600), isSelf: true),
            TokenDevice(id: pc, name: "工作 PC", lastUpload: now.addingTimeInterval(-2 * 3600)),
            TokenDevice(id: laptop, name: "筆電", lastUpload: now.addingTimeInterval(-3 * 86400 - 600)),
        ], uploadRevoked: revoked)
        return data
    }

    private static func renderTier2(_ local: TokenStatsData, to dir: URL) {
        guard local.hasData else { return }
        let data = tier2Sample(local)
        let pc = TokenDeviceScope.device("0f8e2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b")
        var noUpload = data
        noUpload.devices.devices.append(TokenDevice(id: "2b3c4d5e-1b2d-4e5f-8a9b-0c1d2e3f4a5b", name: "新電腦"))
        for scheme in [ColorScheme.light, .dark] {
            let n = scheme.name
            write(statsCard(data, device: .all), scheme: scheme, to: dir.appendingPathComponent("tier2-card-all-\(n).png"))
            write(statsCard(data, device: .thisMac), scheme: scheme, to: dir.appendingPathComponent("tier2-card-this-mac-\(n).png"))
            write(statsCard(data, device: pc), scheme: scheme, to: dir.appendingPathComponent("tier2-card-pc-\(n).png"))
            write(statsCard(noUpload, device: .device("2b3c4d5e-1b2d-4e5f-8a9b-0c1d2e3f4a5b")), scheme: scheme,
                  to: dir.appendingPathComponent("tier2-card-no-upload-\(n).png"))
            write(statsCard(tier2Sample(local, revoked: true), device: .all), scheme: scheme, to: dir.appendingPathComponent("tier2-card-revoked-\(n).png"))
            if var full = HistoryStore.shared.loadFullTokenStats() {
                full.days = data.days
                full.devices = data.devices
                for (device, name) in [(TokenDeviceScope.all, "all"), (pc, "pc")] {
                    PanelSettings.shared.statsDevice = device
                    write(StatsWindowView(historyStore: HistoryStore.shared, fixedData: full, fixedMotion: .settled, scrolls: false).frame(width: 860),
                          scheme: scheme, to: dir.appendingPathComponent("tier2-window-\(name)-\(n).png"))
                }
                PanelSettings.shared.statsDevice = nil
            }
        }
    }

    // MARK: - 服務狀態（第四階段）

    private static func statusRows(_ health: [String: ServiceHealth], exhausted: Set<String> = []) -> [ServiceStatusRow] {
        ["claude", "codex"].map { ServiceStatusRow(provider: $0, health: health[$0] ?? .operational, quotaExhausted: exhausted.contains($0)) }
    }

    private static func statusCard(_ rows: [ServiceStatusRow], motion: PanelMotion = .settled) -> some View {
        Group {
            if ServiceStatusRow.allQuiet(rows) {
                ServiceStatusLine(rows: rows)
            } else {
                PanelCard(id: PanelSection.status.rawValue, title: PanelSection.status.title, collapsed: .constant(false)) {
                    ServiceStatusCardContent(rows: rows)
                }
            }
        }
        .frame(width: 328)
        .padding(16)
        .environment(\.panelMotion, motion)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 服務狀態的各種情況（假資料，事件名稱都是編的）
    private static let statusCases: [(String, [ServiceStatusRow])] = [
        ("normal", statusRows([:])),
        ("disrupted", statusRows(["claude": .disrupted(summary: "示範：Claude Code 回應變慢", affectsTool: true)])),
        ("quota", statusRows([:], exhausted: ["claude"])),
        ("both", statusRows(["claude": .disrupted(summary: "示範：API 錯誤率升高", affectsTool: true)], exhausted: ["claude"])),
        ("maintenance", statusRows(["codex": .maintenance(summary: "示範：排定的維護")])),
        ("unknown", statusRows(["claude": .unknown, "codex": .unknown])),
    ]

    private static func renderStatus(to dir: URL) {
        for scheme in [ColorScheme.light, .dark] {
            for (name, rows) in statusCases {
                write(statusCard(rows), scheme: scheme, to: dir.appendingPathComponent("status-\(name)-\(scheme.name).png"))
            }
        }
    }

    /// 服務異常：橘點呼吸 3 次後停止（3 × 0.8 秒）
    private static func renderStatusPulse(to dir: URL) {
        let rows = statusCases[1].1
        for scheme in [ColorScheme.light, .dark] {
            var frames: [CGImage] = []
            for index in 0...Int(2.7 * fps) {
                var m = PanelMotion.settled
                m.statusPulse = min(Double(index) / fps / 0.8, PanelTiming.statusPulses)
                if let image = cgImage(statusCard(rows, motion: m), scheme: scheme) { frames.append(image) }
            }
            writeFrames(frames, name: "anim-status-pulse-\(scheme.name)", in: dir)
        }
    }

    private static func renderSettings(to dir: URL) {
        for scheme in [ColorScheme.light, .dark] {
            let view = SettingsView(scrolls: false)
                .environment(UsageStore.shared)
                .environment(PanelSettings.shared)
                .environment(HistoryStore.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            write(view, scheme: scheme, to: dir.appendingPathComponent("settings-\(scheme.name).png"))
            // 系統設定中關閉了通知時的提示
            let denied = NotificationSettingsSection(interactive: false, previewDenied: true)
                .environment(PanelSettings.shared)
                .frame(width: 420, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            write(denied, scheme: scheme, to: dir.appendingPathComponent("settings-notify-denied-\(scheme.name).png"))
        }
    }

    /// 四種狀態 × 四種樣式，放在模擬的選單列上。
    private static func renderMenuBarIcons(to dir: URL) {
        let states: [(String, MenuBarIconContent)] = [
            ("正常", .init(provider: "claude", remainingPct: 62, timeRemaining: 70, state: .normal, label: "Claude 5 小時")),
            ("用得太快", .init(provider: "claude", remainingPct: 27, timeRemaining: 40, state: .tooFast, label: "Claude 5 小時")),
            ("剩不到 20%", .init(provider: "codex", remainingPct: 12, timeRemaining: 30, state: .critical, label: "Codex 每週")),
            ("資料過期", .init(provider: "claude", remainingPct: 62, timeRemaining: 70, state: .stale, label: "Claude 5 小時")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 10) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    HStack(spacing: 18) {
                        Text(style.title).font(.caption).frame(width: 56, alignment: .leading)
                        ForEach(states, id: \.0) { title, content in
                            HStack(spacing: 6) {
                                MenuBarIconView(content: content, style: style).font(.system(size: 13))
                                Text(title).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 120, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                }
            }
            .padding(12)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.9))
            write(view, scheme: scheme, to: dir.appendingPathComponent("menubar-icons-\(scheme.name).png"))
        }
    }

    // MARK: - 動畫的 PNG 序列與 GIF

    private static let fps = 30.0

    private static func renderAnimations(to dir: URL, only: Set<String>?) {
        let animations: [(String, Double, (Double) -> PanelMotion)] = [
            // 主圓環與用量條從 0 長到目前位置，預期標記稍後淡入
            ("appear", 0.9, { t in
                PanelMotion(appear: Curve.easeOut(t / 0.6), marker: Curve.easeOut((t - 0.45) / 0.2))
            }),
            // 更新按鈕轉一圈，完成後狀態點閃一下
            ("refresh", 1.3, { t in
                var m = PanelMotion.settled
                m.refreshTurns = Curve.easeInOut(t / 0.6)
                m.dotFlash = t > 0.6 ? Curve.linear((t - 0.6) / 0.5) : 0
                if m.dotFlash >= 1 { m.dotFlash = 0 }
                return m
            }),
            // 額度重置：服務圖示閃一下光芒
            ("reset-glow", 1.0, { t in
                var m = PanelMotion.settled
                let p = Curve.linear(t / 0.8)
                m.glow = ["claude": p >= 1 ? 0 : p]
                return m
            }),
            // 卡片收合再展開
            ("collapse", 1.0, { t in
                var m = PanelMotion.settled
                let p = t < 0.5 ? 1 - Curve.easeInOut(t / 0.25) : Curve.easeInOut((t - 0.5) / 0.25)
                m.reveal = [PanelSection.ring.rawValue: p]
                return m
            }),
            // 第二階段（ADR-0010）：走勢曲線由左往右描繪，最後的圓點輕彈一下
            ("trend", 0.9, { t in
                var m = PanelMotion.settled
                m.trend = Curve.easeOut(t / 0.6)
                return m
            }),
            // 「建議接下來用」從上方滑入
            ("suggest", 0.6, { t in
                var m = PanelMotion.settled
                m.suggest = Curve.easeOut(t / 0.3)
                return m
            }),
            // 重置時間軸的圓點依序滑到位置
            ("timeline", 0.8, { t in
                var m = PanelMotion.settled
                m.timeline = Curve.easeOut(t / 0.5)
                return m
            }),
            // 額度重置：時間軸上的圓點在「現在」放大淡出，服務圖示同時閃光
            ("reset-departing", 1.0, { t in
                var m = PanelMotion.settled
                let p = Curve.easeOut(t / 0.5)
                if p < 1 { m.departing = ["claude/five_hour": p] }
                let g = Curve.linear(t / 0.8)
                m.glow = ["claude": g >= 1 ? 0 : g]
                return m
            }),
            // 第四階段：點通知打開面板時，額度卡片亮一下（0.6 秒）
            ("highlight", 0.9, { t in
                var m = PanelMotion.settled
                let p = Curve.easeOut(t / 0.6)
                if p < 1 { m.highlight = [PanelSection.quota.rawValue: p] }
                return m
            }),
            // 歷史不足時的骨架畫面：掃光三次後停止
            ("skeleton", 3.9, { t in
                var m = PanelMotion.settled
                m.shimmer = min(t / 1.2, PanelTiming.shimmerPasses)
                return m
            }),
        ]
        for (name, duration, motionAt) in animations where only?.contains(name) ?? true {
            for scheme in [ColorScheme.light, .dark] {
                let folder = dir.appendingPathComponent("anim-\(name)-\(scheme.name)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var frames: [CGImage] = []
                let count = Int(duration * fps) + 1
                for index in 0..<count {
                    let view = panel(motionAt(Double(index) / fps)).background(Color(nsColor: .windowBackgroundColor))
                    guard let image = cgImage(view, scheme: scheme) else { continue }
                    writePNG(image, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
                    frames.append(image)
                }
                writeGIF(frames, to: dir.appendingPathComponent("anim-\(name)-\(scheme.name).gif"))
            }
        }
        renderStatsAnimations(to: dir, only: only)
        if only?.contains("status-pulse") ?? true { renderStatusPulse(to: dir) }
        if only?.contains("trend-switch") ?? true { renderTrendSwitch(to: dir) }
        if only?.contains("theme") ?? true { renderThemeCrossfade(to: dir) }
    }

    /// 第三階段的動畫：只輸出統計卡片（面板寬度），GIF 比較小
    private static func renderStatsAnimations(to dir: URL, only: Set<String>?) {
        let data = HistoryStore.shared.tokens
        guard data.hasData else { return }
        let animations: [(String, Double, (Double) -> (PanelMotion, TokenScope))] = [
            // Token 長條由下往上依序長出（每根晚 15ms，共 ≤ 0.9 秒）
            ("stats-bars", 1.1, { t in
                var m = PanelMotion.settled
                m.statsBars = Curve.linear(t / 0.9)
                return (m, .all)
            }),
            // 活動熱力圖由左到右以欄為單位淡入（≤ 1.0 秒）
            ("stats-heatmap", 1.2, { t in
                var m = PanelMotion.settled
                m.heatmap = Curve.linear(t / 1.0)
                return (m, .all)
            }),
            // 連續天數創新紀錄：🔥 彈一下（每個新紀錄一次）
            ("stats-streak", 1.0, { t in
                var m = PanelMotion.settled
                let p = Curve.easeOut((t - 0.2) / 0.5)
                m.streakPop = p >= 1 ? 0 : p
                return (m, .all)
            }),
        ]
        for (name, duration, at) in animations where only?.contains(name) ?? true {
            for scheme in [ColorScheme.light, .dark] {
                var frames: [CGImage] = []
                for index in 0...Int(duration * fps) {
                    let (m, scope) = at(Double(index) / fps)
                    if let image = cgImage(statsCard(data, scope: scope, motion: m), scheme: scheme) { frames.append(image) }
                }
                writeFrames(frames, name: "anim-\(name)-\(scheme.name)", in: dir)
            }
        }
        // 切換服務：交叉淡入 0.3 秒（新畫面的長條與熱力圖同時重新長出）。SwiftUI 的交叉淡入無法逐格指定，以兩張畫面的混合示意
        guard only?.contains("stats-switch") ?? true, data.providers.count > 1 else { return }
        for scheme in [ColorScheme.light, .dark] {
            guard let old = cgImage(statsCard(data, scope: .all), scheme: scheme) else { continue }
            var frames: [CGImage] = []
            for index in 0...Int(1.1 * fps) {
                let t = Double(index) / fps
                var m = PanelMotion.settled
                m.statsBars = Curve.linear(t / 0.9)
                m.heatmap = Curve.linear(t / 1.0)
                guard let new = cgImage(statsCard(data, scope: .claude, motion: m), scheme: scheme),
                      let frame = blend(new, old, 1 - Curve.easeInOut(t / 0.3)) else { continue }
                frames.append(frame)
            }
            writeFrames(frames, name: "anim-stats-switch-\(scheme.name)", in: dir)
        }
    }

    private static func writeFrames(_ frames: [CGImage], name: String, in dir: URL) {
        let folder = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            writePNG(frame, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
        }
        writeGIF(frames, to: dir.appendingPathComponent("\(name).gif"))
    }

    /// 切換走勢的額度：舊曲線淡出（0.3 秒交叉淡入），新曲線重新由左往右描繪。
    /// SwiftUI 的交叉淡入無法逐格指定，這裡以兩張畫面的混合示意。
    private static func renderTrendSwitch(to dir: URL) {
        let settings = PanelSettings.shared
        guard let snapshot = UsageStore.shared.snapshot else { return }
        let options = HistoryWindowOption.options(snapshot)
        guard options.count > 1, let current = HistoryWindowOption.resolve(settings.trendWindow, in: options),
              let index = options.firstIndex(of: current) else { return }
        let next = options[(index + 1) % options.count].id
        defer { settings.trendWindow = current.id }
        for scheme in [ColorScheme.light, .dark] {
            settings.trendWindow = current.id
            guard let old = cgImage(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: scheme) else { continue }
            settings.trendWindow = next
            let folder = dir.appendingPathComponent("anim-trend-switch-\(scheme.name)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var frames: [CGImage] = []
            for index in 0...Int(0.9 * fps) {
                let t = Double(index) / fps
                var m = PanelMotion.settled
                m.trend = Curve.easeOut(t / 0.6)
                guard let new = cgImage(panel(m).background(Color(nsColor: .windowBackgroundColor)), scheme: scheme),
                      let frame = blend(new, old, 1 - Curve.easeInOut(t / 0.3)) else { continue }
                writePNG(frame, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
                frames.append(frame)
            }
            writeGIF(frames, to: dir.appendingPathComponent("anim-trend-switch-\(scheme.name).gif"))
        }
    }

    /// 深淺色切換：SwiftUI 在兩個外觀的顏色之間過渡；這裡以兩張截圖的交叉淡入示意（0.3 秒）。
    private static func renderThemeCrossfade(to dir: URL) {
        guard let light = cgImage(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: .light),
              let dark = cgImage(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: .dark) else { return }
        let folder = dir.appendingPathComponent("anim-theme")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var frames: [CGImage] = []
        let count = Int(0.3 * fps) + 1
        for index in 0..<(count * 2 + 10) {
            // 淺→深、停留、深→淺
            let t = Double(index) / Double(count - 1)
            let mix = index < count ? Curve.easeInOut(t) : index < count + 10 ? 1 : 1 - Curve.easeInOut(Double(index - count - 10) / Double(count - 1))
            guard let frame = blend(light, dark, mix) else { continue }
            writePNG(frame, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
            frames.append(frame)
        }
        writeGIF(frames, to: dir.appendingPathComponent("anim-theme.gif"))
    }

    // MARK: - 輸出

    private static func cgImage(_ view: some View, scheme: ColorScheme) -> CGImage? {
        let content = view.environment(\.colorScheme, scheme).environment(\.panelStill, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        // UsageColors 的動態顏色依「目前的繪製外觀」解析，所以外觀也要一起切換
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    private static func write(_ view: some View, scheme: ColorScheme, to url: URL) {
        guard let image = cgImage(view, scheme: scheme) else { return }
        writePNG(image, to: url)
        UsageStore.log("rendered \(url.lastPathComponent)")
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, delay) }
        CGImageDestinationFinalize(destination)
        UsageStore.log("rendered \(url.lastPathComponent) (\(frames.count) frames)")
    }

    private static func blend(_ a: CGImage, _ b: CGImage, _ mix: Double) -> CGImage? {
        let width = max(a.width, b.width), height = max(a.height, b.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(a, in: CGRect(x: 0, y: height - a.height, width: a.width, height: a.height))
        context.setAlpha(mix)
        context.draw(b, in: CGRect(x: 0, y: height - b.height, width: b.width, height: b.height))
        return context.makeImage()
    }
}

/// 量測腳本觸發面板動畫的方式（只在 Debug 版本）。
enum DebugAction {
    static let notification = Notification.Name("AUMDebugPanelAction")

    @MainActor static func send(_ action: String) {
        NotificationCenter.default.post(name: notification, object: action)
    }
}

/// 與 SwiftUI 內建曲線相同的三次貝茲曲線（easeOut＝0,0,0.58,1；easeInOut＝0.42,0,0.58,1）。
private enum Curve {
    static func linear(_ t: Double) -> Double { min(max(t, 0), 1) }
    static func easeOut(_ t: Double) -> Double { bezier(linear(t), 0, 0, 0.58, 1) }
    static func easeInOut(_ t: Double) -> Double { bezier(linear(t), 0.42, 0, 0.58, 1) }

    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func component(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if component(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return component(t, y1, y2)
    }
}

private extension ColorScheme {
    var name: String { self == .dark ? "dark" : "light" }
}
#endif
