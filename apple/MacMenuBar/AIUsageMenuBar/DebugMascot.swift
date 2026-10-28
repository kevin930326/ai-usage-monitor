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
    }

    enum Quota { case normal, low, stale }

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
            }
            return snapshot
        }
        func canvas(_ shot: Shot) -> some View {
            NotchCanvas(director: director(shot), time: shot.time, layout: shot.layout, snapshot: quotaSnapshot(shot.quota), now: now,
                        character: shot.character, gazeOverride: (0, 0))
        }
        func label(_ text: String) -> some View {
            Text(text).font(.system(size: 11)).foregroundStyle(Color(white: 0.75)).frame(width: 580, alignment: .leading)
        }

        // 收合：Claude、Codex，三種狀態點
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
            expression("dizzy", at: 1200) { $0.request(.dizzy, at: 1000) },
            expression("shy", at: 700) { $0.request(.shy, at: 1000) },
            expression("shy-peek", at: 1200) { $0.request(.shy, at: 1000) },
            expression("scared", at: 700) { $0.request(.scared, at: 1000) },
            expression("squeeze", at: 600) { $0.press(at: 1000) },
            expression("sleep", at: 11_000) { _ in },
            expression("wake", at: 11_200) { $0.advance(to: 11_000); $0.move(at: 11_000, dx: 0, dy: 0) },
            expression("work", at: 800) { $0.setWorking(true, at: 1000) },
            expression("alert-high", at: 250) { $0.setStatus(1, at: 1000) },
            expression("alert-out", at: 250) { $0.setStatus(2, at: 1000) },
            Shot(name: "expr-collapsed-alert", setup: { $0.setStatus(1, at: 1000) }, time: 1350),
        ]
        // 有瀏海的 Mac（實體瀏海 185 寬）與沒有瀏海時的假瀏海
        let notch = NotchLayout(notchWidth: 185, notchHeight: 32, hasNotch: true)
        let screens = [
            Shot(name: "notch-collapsed", layout: notch, setup: { _ in }, time: 1000),
            Shot(name: "fake-collapsed", layout: .fake, setup: { _ in }, time: 1000),
        ]

        let all = collapsed + expanded + intro + expressions + screens
        for shot in all {
            write(canvas(shot).background(Color(white: 0.16)), dir.appendingPathComponent("mascot-\(shot.name).png"))
        }

        // 合成的對照圖（截圖基準）
        func sheet(_ shots: [Shot], height: Double = 190) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shots.enumerated()), id: \.offset) { _, shot in
                    label(shot.name)
                    canvas(shot).frame(width: 580, height: height, alignment: .top).clipped()
                }
            }
            .padding(10)
            .background(Color(white: 0.16))
        }
        write(sheet(collapsed, height: 40), dir.appendingPathComponent("notch-collapsed.png"))
        write(sheet(expanded + intro), dir.appendingPathComponent("notch-intro.png"))
        write(sheet(expressions), dir.appendingPathComponent("notch-expressions.png"))
        for scheme in [ColorScheme.light, .dark] {
            write(menuBar(screens.map { ($0.name, canvas($0)) }, scheme: scheme), dir.appendingPathComponent("notch-menubar-\(scheme == .dark ? "dark" : "light").png"))
        }
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
