import SwiftUI
import UsageKit

/// 設定的「角色外觀」（ADR-0021）：每個外觀用實際的角色畫一格預覽（大的是展開時、小的是收合時的迷你角色），點一下選。
/// 預覽是靜態的一格，設定頁開著也不重畫。
struct MascotLookPicker: View {
    let config: MascotConfig
    let looks: MascotLooks
    let character: MascotCharacter
    let selected: String?
    let select: (String?) -> Void

    var body: some View {
        // 依分組的順序排成一片（分組名稱放在滑鼠提示與 VoiceOver，設定頁不另外佔行）
        let items: [MascotLook?] = [nil] + looks.groups.flatMap { group in looks.looks.filter { $0.group == group.id } }
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.?.id) { look in
                tile(look)
            }
        }
    }

    private func groupName(_ look: MascotLook) -> String {
        looks.groups.first { $0.id == look.group }?.name ?? ""
    }

    private func tile(_ look: MascotLook?) -> some View {
        let isSelected = look?.id == selected || (look == nil && selected == nil)
        let name = look?.name ?? "跟著服務"
        return Button { select(look?.id) } label: {
            VStack(spacing: 4) {
                MascotLookPreview(config: config, look: look, character: character)
                    .frame(width: 72, height: 52)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                Text(name).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.map { "\(groupName($0))：\($0.name)，\(Self.describe($0))" } ?? "跟著服務：\(character.title) 的服務色")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(look.map { "\(groupName($0))・\(Self.describe($0))" } ?? "Claude 是珊瑚色、Codex 是青瓷色（目前的樣子）")
    }

    /// VoiceOver 與滑鼠提示
    static func describe(_ look: MascotLook) -> String {
        switch look.style {
        case .solid, .linear: look.blush ? "有腮紅" : look.eye != nil ? "深色身體、亮色眼睛" : "單色"
        case .led: "琥珀色 LED 點陣，有一道掃描光"
        case .pixel: "大格子像素、三階明暗"
        case .neon: "發光的外框，會呼吸"
        case .wire: "經緯線組成的球，會慢慢轉"
        case .ascii: "用字元畫的，字元會微微跳動"
        }
    }
}

/// 一格靜態預覽：左邊展開時的角色（半徑 16），右下收合時的迷你角色（半徑 9）
struct MascotLookPreview: View {
    let config: MascotConfig
    let look: MascotLook?
    let character: MascotCharacter
    var effectTime: Int?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let painter = MascotPainter(config: config, canvasWidth: size.width, panelHeight: size.height)
            let base = MascotScripts(config: config).cardPose
            for (x, y, r) in [(size.width * 0.38, size.height * 0.5, 16.0), (size.width - 13, size.height - 12, 9.0)] {
                var pose = base.with([.x: x, .y: y, .r: r, .glow: r > 12 ? 0.35 : 0])
                pose[.hands] = 0
                let frame = MascotFrame(time: 0, pose: pose, eyes: .pill, blink: 0, gazeYaw: 0, gazePitch: 0, statusColor: 0,
                                        sleeping: false, effects: [], ripple: nil, character: character, look: look,
                                        effectTime: effectTime)
                _ = painter.drawHero(frame, in: &context)
            }
        }
        .accessibilityHidden(true)
    }
}
