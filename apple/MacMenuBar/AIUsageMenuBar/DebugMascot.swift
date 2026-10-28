#if DEBUG
import SwiftUI
import UsageKit
import UsageKitUI

/// 瀏海面板與角色的截圖（ADR-0016 第 1 節）：以固定的時間點與種子組出畫面，用 ImageRenderer 輸出 PNG。
/// 個別的圖給設計比對；合成的對照圖（`notch-*.png`）放進截圖基準（`scripts/snapshots.sh`）。
@MainActor
enum DebugMascot {
    struct Shot {
        var name: String
        var character: MascotCharacter = .claude
        var layout = NotchLayout.fake
        var setup: (inout MascotDirector) -> Void
        var time: Int
        /// 額度的情境：剩不到 20%、資料過期（迷你圓環與額度列的顏色）
        var quota: Quota = .normal
        /// AI 工作階段（外框、數量、列表）與等你時的脈動（0…1）
        var extras = NotchExtras()
        var pulse: Double?
    }

    enum Quota { case normal, low, stale, forecast, incident }

    static func render(to dir: URL, snapshot: UsageSnapshot?, now: Date, write: (any View, URL) -> Void) {
        guard let data = MascotController.bundledConfig(), let config = try? MascotConfig.decode(data) else {
            UsageStore.log("mascot-anim.json missing; skipped notch screenshots")
            return
        }
        func director(_ shot: Shot) -> MascotDirector {
            var config = config
            config.hero.mini = MascotConfig.Point(x: shot.layout.miniX, y: shot.layout.miniY, radius: config.hero.mini.radius)
            config.panel.collapsed.width = shot.layout.collapsedWidth
            config.panel.collapsed.height = shot.layout.collapsedHeight
            var d = MascotDirector(config: config, seed: 7, startTime: 0)
            shot.setup(&d)
            // 沒有指定表情時照額度：過期閉眼、剩不到 20% 擔心、用完 ×
            if d.mood == .normal {
                let data = quotaSnapshot(shot.quota)
                d.setMood(.quota(level: d.machine.statusLevel, unavailable: shot.quota == .stale,
                                 incident: MascotMood.hasIncident(data, provider: shot.character.provider),
                                 runsOut: MascotMood.runsOut(data, provider: shot.character.provider, now: now)))
            }
            d.advance(to: shot.time)
            return d
        }
        func quotaSnapshot(_ quota: Quota) -> UsageSnapshot? {
            guard var snapshot else { return nil }
            switch quota {
            case .normal: break
            case .low:
                // Claude 的每個額度剩 12%
                if var claude = snapshot.providers["claude"] {
                    claude.windows = claude.windows.map { var w = $0; w.usedPct = 88; return w }
                    snapshot.providers["claude"] = claude
                }
            case .stale:
                snapshot.updatedAt = now.addingTimeInterval(-3 * 3600)
            case .forecast:
                // ADR-0018：Claude 的額度照目前速度會在重置前用完（收集器算好的）
                if var claude = snapshot.providers["claude"] {
                    claude.windows = claude.windows.map { w in
                        var w = w
                        guard let resets = w.resetsAt, !w.hidden else { return w }
                        let at = now.addingTimeInterval(min(resets.timeIntervalSince(now) * 0.6, w.id == "five_hour" ? 40 * 60 : 20 * 3600))
                        w.forecast = QuotaForecast(exhaustsAt: at, urgent: false, faster: w.id == "five_hour" ? 2.1 : nil)
                        return w
                    }
                    snapshot.providers["claude"] = claude
                }
            case .incident:
                snapshot.providers["claude"]?.incidents = [
                    ServiceIncident(name: "Elevated errors on Claude Code", impact: "major",
                                    url: "https://status.claude.com/incidents/demo", startedAt: now.addingTimeInterval(-1200)),
                ]
            }
            return snapshot
        }
        func canvas(_ shot: Shot) -> some View {
            let d = director(shot)
            let size = d.config.panel.collapsed
            return NotchCanvas(director: d, time: shot.time, layout: shot.layout, snapshot: quotaSnapshot(shot.quota), now: now,
                               character: shot.character, extras: shot.extras, gazeOverride: (0, 0))
                .overlay {
                    if let pulse = shot.pulse {
                        NotchPulse.glow(NotchShape(width: size.width, height: size.height, corner: size.corner), phase: pulse)
                    }
                }
        }
        func label(_ text: String) -> some View {
            Text(text).font(.system(size: 11)).foregroundStyle(Color(white: 0.75)).frame(width: 580, alignment: .leading)
        }

        // 收合：Claude、Codex，三種額度表情（正常膠囊、擔心的小圓點＋眉毛、用完 ×）
        var collapsed: [Shot] = []
        for character in MascotCharacter.allCases {
            for level in 0...2 {
                collapsed.append(Shot(name: "collapsed-\(character.rawValue)-\(["normal", "high", "out"][level])",
                                      character: character, setup: { $0.setStatus(level, at: 0) }, time: 2000))
            }
        }
        // 剩不到 20%（紅）、資料過期（灰、虛線）
        for quota in [Quota.low, .stale] {
            collapsed.append(Shot(name: "collapsed-claude-\(quota == .low ? "low" : "stale")",
                                  setup: { $0.setStatus(quota == .low ? 1 : 0, at: 0) }, time: 2000, quota: quota))
        }
        // 收著時 Claude 與 Codex 都閒置：迷你角色閉眼低頭（靜止）
        for character in MascotCharacter.allCases {
            collapsed.append(Shot(name: "collapsed-\(character.rawValue)-sleep", character: character,
                                  setup: { $0.setAgentIdle(true, at: 0) }, time: 2000))
        }
        // 展開（不播過場、已經停在角色卡）
        var expanded = [MascotCharacter.claude, .codex].map { character in
            Shot(name: "expanded-\(character.rawValue)", character: character,
                 setup: { $0.open(at: 0, intro: false) }, time: 1500)
        }
        for quota in [Quota.low, .stale] {
            expanded.append(Shot(name: "expanded-claude-\(quota == .low ? "low" : "stale")",
                                 setup: { $0.setStatus(quota == .low ? 1 : 0, at: 0); $0.open(at: 0, intro: false) },
                                 time: 1500, quota: quota))
        }
        expanded.append(Shot(name: "expanded-claude-out", setup: { $0.setStatus(2, at: 0); $0.open(at: 0, intro: false) },
                             time: 1500))
        // 過場的六個時間點
        let intro = [0, 300, 1200, 2600, 3990, 4700].map { ms in
            Shot(name: "intro-\(ms)", setup: { $0.open(at: 0, intro: true) }, time: ms)
        }
        // 每個表情的中段（展開 1 秒後觸發）
        func expression(_ name: String, at offset: Int, _ trigger: @escaping (inout MascotDirector) -> Void) -> Shot {
            Shot(name: "expr-\(name)", setup: { d in
                d.open(at: 0, intro: false)
                d.advance(to: 1000)
                trigger(&d)
            }, time: 1000 + offset)
        }
        let expressions: [Shot] = [
            expression("hop", at: 300) { $0.request(.hop, at: 1000) },
            expression("wave", at: 700) { $0.request(.wave, at: 1000) },
            expression("nod", at: 260) { $0.request(.nod, at: 1000) },
            expression("tilt", at: 500) { $0.request(.tilt, at: 1000) },
            expression("giggle", at: 400) { $0.request(.giggle, at: 1000) },
            expression("look", at: 650) { $0.request(.look, at: 1000) },
            expression("pinch", at: 250) { $0.request(.pinch, at: 1000) },
            expression("dizzy", at: 1200) { $0.request(.dizzy, at: 1000) },
            expression("shy", at: 700) { $0.request(.shy, at: 1000) },
            expression("shy-peek", at: 1200) { $0.request(.shy, at: 1000) },
            expression("scared", at: 700) { $0.request(.scared, at: 1000) },
            expression("squeeze", at: 600) { $0.press(at: 1000) },
            expression("sleep", at: 2000) { $0.setAgentIdle(true, at: 1000) },
            expression("wake", at: 2200) { $0.setAgentIdle(true, at: 1000); $0.click(at: 2000, choice: .hop) },
            expression("work", at: 800) { $0.setWorking(true, at: 1000) },
            expression("alert-high", at: 250) { $0.setStatus(1, at: 1000) },
            expression("alert-out", at: 250) { $0.setStatus(2, at: 1000) },
            Shot(name: "expr-collapsed-alert", setup: { $0.setStatus(1, at: 1000) }, time: 1350),
        ] + MascotMood.allCases.filter { $0 != .normal }.map { mood in
            // 右鍵選單的「表情」（同一套眼睛與眉毛也用在額度與之後的 AI 狀態）
            expression("face-\(mood.rawValue)", at: 1000) { $0.requestFace(mood, at: 1000) }
        }
        // AI 狀態（mascot2 第 2 部分）：需要你（舉手、琥珀外框、數量）、收著時完成（鼓一下、揮手）、
        // 等你下指令的脈動、展開的工作階段列表、出錯（難過）
        func row(_ ai: AgentKind, _ folder: String, _ state: AgentState, need: AgentNeed? = nil, minutes: Int) -> NotchAgentRow {
            NotchAgentRow(id: "\(ai.rawValue)/\(folder)", ai: ai, folder: folder, state: state, need: need, minutes: minutes)
        }
        let needsRows = [row(.claude, "ai-usage-monitor", .needsYou, need: .permission, minutes: 2),
                         row(.codex, "web-app", .working, minutes: 14)]
        let manyRows = [row(.claude, "ai-usage-monitor", .needsYou, need: .question, minutes: 0),
                        row(.codex, "billing-service", .error, minutes: 3),
                        row(.claude, "web-app", .working, minutes: 74),
                        row(.codex, "notes", .done, minutes: 1),
                        row(.claude, "dotfiles", .waiting, minutes: 9)]
        let agents: [Shot] = [
            Shot(name: "collapsed-needs-you", setup: { $0.setNeedsYou(true, at: 0) }, time: 2000,
                 extras: NotchExtras(agents: needsRows)),
            Shot(name: "collapsed-cheer", setup: { $0.advance(to: 1000); $0.cheer(at: 1000) }, time: 1700),
            Shot(name: "collapsed-waiting-pulse", setup: { _ in }, time: 2000,
                 extras: NotchExtras(agents: [row(.claude, "ai-usage-monitor", .waiting, minutes: 1)]), pulse: 0.5),
            Shot(name: "expanded-agents", setup: { $0.setNeedsYou(true, at: 0); $0.open(at: 0, intro: false) }, time: 1500,
                 extras: NotchExtras(page: .agents, agents: manyRows)),
            Shot(name: "expanded-agent-error", setup: { $0.setMood(.sad); $0.open(at: 0, intro: false) }, time: 1500,
                 extras: NotchExtras(agents: [row(.codex, "billing-service", .error, minutes: 3)])),
            // 其他電腦（ADR-0019 第 2 節）：接在這台之後，電腦圖示＋裝置名稱
            Shot(name: "expanded-agents-remote", setup: { $0.open(at: 0, intro: false) }, time: 1500,
                 extras: NotchExtras(page: .agents, agents: [row(.claude, "ai-usage-monitor", .working, minutes: 6)],
                                     remote: [RemoteAgent(device: "工作 PC", ai: .codex, state: .needsYou, sessions: 1),
                                              RemoteAgent(device: "桌機", ai: .claude, state: .working, sessions: 2)])),
        ]
        // 有瀏海的 Mac（實體瀏海 185 寬）與沒有瀏海時的假瀏海
        let notch = NotchLayout(notchWidth: 185, notchHeight: 32, hasNotch: true)
        let screens = [
            Shot(name: "notch-collapsed", layout: notch, setup: { _ in }, time: 1000),
            Shot(name: "fake-collapsed", layout: .fake, setup: { _ in }, time: 1000),
        ]

        let all = collapsed + expanded + intro + expressions + agents + screens
        for shot in all {
            write(canvas(shot).background(Color(white: 0.16)), dir.appendingPathComponent("mascot-\(shot.name).png"))
        }

        // 合成的對照圖（截圖基準）
        func sheet(_ shots: [Shot], height: Double = 190, collapsedHeight: Double? = nil) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shots.enumerated()), id: \.offset) { _, shot in
                    label(shot.name)
                    canvas(shot).frame(width: 580, height: shot.name.hasPrefix("collapsed") ? collapsedHeight ?? height : height,
                                       alignment: .top).clipped()
                }
            }
            .padding(10)
            .background(Color(white: 0.16))
        }
        write(sheet(collapsed, height: 40), dir.appendingPathComponent("notch-collapsed.png"))
        write(sheet(expanded + intro), dir.appendingPathComponent("notch-intro.png"))
        write(sheet(expressions), dir.appendingPathComponent("notch-expressions.png"))
        write(sheet(agents, collapsedHeight: 44), dir.appendingPathComponent("notch-agents.png"))
        // ADR-0018：預測會用完（擔心＋額度卡最後一行）、服務事故（生病＋事故名稱）
        write(VStack(spacing: 0) {
            sheet([
                Shot(name: "expanded-claude-forecast", setup: { $0.open(at: 0, intro: false) }, time: 1500, quota: .forecast),
                Shot(name: "expanded-claude-incident", setup: { $0.open(at: 0, intro: false) }, time: 1500, quota: .incident),
            ])
            sheet([
                Shot(name: "collapsed-claude-forecast", setup: { _ in }, time: 1000, quota: .forecast),
                Shot(name: "collapsed-claude-incident", setup: { _ in }, time: 1000, quota: .incident),
            ], height: 40)
        }, dir.appendingPathComponent("notch-forecast.png"))
        for scheme in [ColorScheme.light, .dark] {
            write(menuBar(screens.map { ($0.name, canvas($0)) }, scheme: scheme), dir.appendingPathComponent("notch-menubar-\(scheme == .dark ? "dark" : "light").png"))
        }
        // 右鍵選單：和真的選單同一份項目（`NotchMenu.entries`），完整與簡單、靜音中各一份
        let quiet = now.addingTimeInterval(3600)
        let menus: [(String, [NotchMenu.Entry])] = [
            ("完整", NotchMenu.entries(animates: true, simple: false, pinned: false, quietUntil: nil)),
            ("保持展開、靜音中", NotchMenu.entries(animates: true, simple: false, pinned: true, quietUntil: quiet)),
            ("簡單", NotchMenu.entries(animates: false, simple: true, pinned: false, quietUntil: nil)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            write(menuSheet(menus, scheme: scheme), dir.appendingPathComponent("notch-menu-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// 右鍵選單的樣子（系統選單的字級與間距；ImageRenderer 畫不出 NSMenu，所以照同一份項目畫）
    private static func menuSheet(_ menus: [(String, [NotchMenu.Entry])], scheme: ColorScheme) -> some View {
        let primary = scheme == .dark ? Color.white : Color.black
        return HStack(alignment: .top, spacing: 16) {
            ForEach(Array(menus.enumerated()), id: \.offset) { _, menu in
                VStack(alignment: .leading, spacing: 6) {
                    Text(menu.0).font(.system(size: 11)).foregroundStyle(primary.opacity(0.6))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(menu.1.enumerated()), id: \.offset) { _, entry in
                            switch entry {
                            case .header(let title):
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(primary.opacity(0.5))
                                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                            case .separator:
                                Rectangle().fill(primary.opacity(0.12)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 10)
                            case .note(let title):
                                Text(title).font(.system(size: 13)).foregroundStyle(primary.opacity(0.35))
                                    .padding(.horizontal, 10).frame(height: 22)
                            case .item(let title, let enabled, let checked, _):
                                HStack(spacing: 4) {
                                    Text(checked ? "✓" : "").font(.system(size: 12, weight: .semibold)).frame(width: 12)
                                    Text(title).font(.system(size: 13))
                                }
                                .foregroundStyle(primary.opacity(enabled ? 0.9 : 0.35))
                                .padding(.leading, 4).padding(.trailing, 20).frame(height: 22)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .frame(width: 250, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary.opacity(0.12)))
                }
            }
        }
        .padding(14)
        .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.86))
        .environment(\.colorScheme, scheme)
    }

    /// 放在模擬的選單列上（淺色、深色），看假瀏海和實體瀏海兩側的樣子
    private static func menuBar(_ items: [(String, some View)], scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0).font(.system(size: 11)).foregroundStyle(scheme == .dark ? Color(white: 0.8) : Color(white: 0.25))
                ZStack(alignment: .top) {
                    Rectangle().fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.93)).frame(height: 32)
                    HStack {
                        Text("檔案　編輯　顯示方式").font(.system(size: 13))
                        Spacer()
                        Text("12:25").font(.system(size: 13))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                    item.1.frame(width: 580, height: 60, alignment: .top).clipped()
                }
                .frame(width: 760, height: 60, alignment: .top)
                .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.8))
            }
        }
        .padding(10)
        .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.97))
    }
}
#endif
