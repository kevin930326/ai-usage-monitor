import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 打開面板的全域快捷鍵（FR-47、ADR-0008 第 7 節）。預設不設定；使用者在設定中錄製。
/// 用 Carbon 的 `RegisterEventHotKey`：不需要「輔助使用」權限，也不監看其他 App 的按鍵。
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` 的 rawValue（只留 ⌘⌥⌃⇧）
    var modifiers: UInt
    /// 顯示用的按鍵名稱（錄製時的字元，例如「K」「F5」「Space」）
    var key: String

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    /// 「⌃⌥⌘K」
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    /// 錄製時按下的鍵；只有 ⇧ 或沒有修飾鍵（會蓋掉一般打字）時不接受，功能鍵 F1～F20 例外
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevant)
        let function = Self.functionKeys[Int(event.keyCode)]
        guard function != nil || !flags.subtracting(.shift).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
        if let function {
            key = function
        } else if let special = Self.specialKeys[Int(event.keyCode)] {
            key = special
        } else {
            let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            key = chars
        }
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
        self.key = key
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> HotKeyShortcut? { try? JSONDecoder().decode(HotKeyShortcut.self, from: data) }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

/// 註冊與取消全域快捷鍵。按下時打開（或關閉）選單列面板。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// 目前註冊的快捷鍵（註冊失敗時為 nil）
    private(set) var registered: HotKeyShortcut?

    /// 依設定註冊；nil＝取消。回傳是否成功（組合已被其他 App 占用時失敗）。
    @discardableResult
    func apply(_ shortcut: HotKeyShortcut?) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        registered = nil
        guard let shortcut else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4155_4D31), id: 1) // 'AUM1'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            UsageStore.log("hot key register failed: \(status)")
            return false
        }
        hotKey = ref
        registered = shortcut
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppActions.togglePanel() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// 設定的「快捷鍵」：錄製、清除；預設不設定（ADR-0008 第 7 節）。
struct HotKeySettingsSection: View {
    @Environment(PanelSettings.self) private var settings
    /// 截圖時不建立按鍵監看
    var interactive = true

    @State private var recording = false
    @State private var monitor: Any?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷鍵").font(.headline)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("打開面板")
                    Text("在任何 App 中按下這個組合打開或關閉選單列面板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: toggleRecording) {
                    Text(recording ? "按下新的組合…" : settings.hotKey?.display ?? "未設定")
                        .font(.callout.monospaced())
                        .frame(minWidth: 96)
                }
                .buttonStyle(PanelPillButtonStyle())
                .accessibilityLabel(recording ? "正在錄製快捷鍵" : "打開面板的快捷鍵：\(settings.hotKey?.display ?? "未設定")")
                .accessibilityHint("按一下後按下新的組合，Esc 取消")
                if settings.hotKey != nil, !recording {
                    Button("清除") {
                        settings.hotKey = nil
                        GlobalHotKey.shared.apply(nil)
                        note = nil
                    }
                    .buttonStyle(PanelPillButtonStyle())
                }
            }
            Text(note ?? "需要 ⌘、⌥ 或 ⌃ 其中之一（功能鍵 F1～F20 可以單獨使用）。右鍵點選單列圖示也可以立即更新、打開完整統計、設定或結束。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard interactive else { return }
        recording = true
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard let shortcut = HotKeyShortcut(event: event) else {
                note = "這個組合不能用：需要 ⌘、⌥ 或 ⌃ 其中之一"
                return nil
            }
            if GlobalHotKey.shared.apply(shortcut) {
                settings.hotKey = shortcut
            } else {
                note = "\(shortcut.display) 已被系統或其他 App 使用，換一個組合"
                GlobalHotKey.shared.apply(settings.hotKey)
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
