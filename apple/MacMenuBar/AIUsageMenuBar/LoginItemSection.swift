import ServiceManagement
import SwiftUI

/// 設定的「登入時自動打開」（SMAppService.mainApp，macOS 13 起）。
/// 只在 App 安裝在「應用程式」資料夾時可以開啟：從 Xcode 的建置資料夾登記的話，
/// 登入項目會指向之後會被清掉或覆蓋的位置。Debug 版的截圖與量測不會改到這個設定。
struct LoginItemSection: View {
    @State private var status = Self.currentStatus()
    @State private var errorText: String?

    private var installed: Bool {
        let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?.path ?? "/Applications"
        return Bundle.main.bundleURL.deletingLastPathComponent().path == applications
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("一般").font(.headline)
            SwitchRow(title: "登入時自動打開", detail: "登入 Mac 後自動在選單列顯示用量", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval }, set: { setEnabled($0) }
            ))
            .disabled(!installed)
            .opacity(installed ? 1 : 0.5)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status == .requiresApproval {
                Button("打開「登入項目」設定") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(PanelPillButtonStyle())
            }
        }
        // 使用者可能在系統設定裡改過
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = Self.currentStatus()
        }
    }

    /// Debug 的截圖與量測（`AUM_DEMO_PANEL`、`AUM_RENDER_DIR`）一律「沒有登記」：不讀這台 Mac 正式安裝那份 App 的登記狀態，
    /// 換一台 Mac 截圖才會一樣
    private static func currentStatus() -> SMAppService.Status {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["AUM_DEMO_PANEL"] == "1" || env["AUM_RENDER_DIR"] != nil { return .notRegistered }
        #endif
        return SMAppService.mainApp.status
    }

    private var note: String? {
        if let errorText { return errorText }
        if !installed { return "先把 App 放進「應用程式」資料夾再開啟。" }
        if status == .requiresApproval { return "需要在「系統設定 › 一般 › 登入項目」允許「AI 用量」。" }
        return nil
    }

    private func setEnabled(_ enabled: Bool) {
        guard installed else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            errorText = enabled ? "無法加入登入項目，可到「系統設定 › 一般 › 登入項目」手動加入。" : "無法移除登入項目，可到「系統設定 › 一般 › 登入項目」手動移除。"
            UsageStore.log("login item \(enabled ? "register" : "unregister") failed: \(type(of: error))")
        }
        status = Self.currentStatus()
    }
}
