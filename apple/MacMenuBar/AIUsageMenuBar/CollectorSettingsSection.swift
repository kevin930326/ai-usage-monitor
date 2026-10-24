import SwiftUI
import UsageKitUI

/// 設定的「背景收集器」（FR-53、ADR-0013 第 3 節）：內建收集器的狀態與操作。
/// 偵測到 install-launchd.sh 的收集器時只提示，按「改用內建收集器」才遷移。
struct CollectorSettingsSection: View {
    @Environment(CollectorService.self) private var collector
    /// 截圖時不執行狀態查詢
    var interactive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("背景收集器").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon.name)
                    .foregroundStyle(icon.color)
                    .accessibilityHidden(true)
                Text(summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title) { Task { await action.run() } }
                    .buttonStyle(PanelPillButtonStyle())
                    .disabled(collector.busy)
            }
            if let error = collector.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if interactive { await collector.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if interactive { Task { await collector.refresh() } }
        }
    }

    private var icon: (name: String, color: Color) {
        switch collector.state {
        case .enabled, .legacy, .devBuild: ("checkmark.circle.fill", .secondary)
        default: ("exclamationmark.circle.fill", UsageColors.notice)
        }
    }

    private var summary: String {
        switch collector.state {
        case .devBuild: "使用 install-launchd.sh 安裝的收集器"
        case .legacy: "正在使用 install-launchd.sh 安裝的收集器"
        case .needsApplicationsFolder: "需要先把 App 放進「應用程式」資料夾"
        case .quarantined: "需要允許內建收集器執行"
        case .notRegistered: "內建收集器已停用"
        case .requiresApproval: "需要在「登入項目」允許背景執行"
        case .enabled: "內建收集器執行中（每 5 分鐘）"
        }
    }

    private var detail: String? {
        if collector.state == .legacy, let blocker = collector.migrationBlocker {
            return switch blocker {
            case .applicationsFolder: "可以改用 App 內建的收集器，但要先把 App 放進「應用程式」資料夾再打開。舊的收集器照常執行。"
            case .quarantine: "可以改用 App 內建的收集器。從瀏覽器下載的 App 帶有隔離標記，先按下按鈕移除 App 自己資料夾內的隔離標記，再改用。"
            }
        }
        return switch collector.state {
        case .devBuild: "這個版本（開發版）沒有內建收集器。"
        case .legacy: "可以改用 App 內建的收集器：之後不需要 Python 與 repo，資料與中繼設定都沿用。改用後舊的排程設定會移到垃圾桶，要回到舊的收集器時停用內建的、再執行一次 install-launchd.sh。"
        case .needsApplicationsFolder: "從 .dmg 或「下載」直接打開時，macOS 會把 App 放在暫時的位置，背景收集器之後會失效。把 App 拖到「應用程式」後再打開。"
        case .quarantined: "從瀏覽器下載的 App 帶有隔離標記，macOS 可能擋下 App 內的收集器。你已經打開過這個 App，按下按鈕會移除 App 自己資料夾內的隔離標記。"
        case .notRegistered: "收集器停用時面板不會更新。資料都還在。"
        case .requiresApproval: "「系統設定 › 一般 › 登入項目與延伸功能」中「AI 用量」被關掉了，打開後每 5 分鐘收集一次。"
        case .enabled: "由 App 註冊的背景項目，會出現在「系統設定 › 一般 › 登入項目與延伸功能」。"
        }
    }

    private var action: (title: String, run: () async -> Void)? {
        switch collector.state {
        case .devBuild, .needsApplicationsFolder: nil
        case .legacy:
            switch collector.migrationBlocker {
            case .applicationsFolder: nil
            case .quarantine: ("允許內建收集器執行", { await collector.allowQuarantinedRuntime() })
            case nil: ("改用內建收集器", { await collector.migrateFromLegacy() })
            }
        case .quarantined: ("允許內建收集器執行", { await collector.allowQuarantinedRuntime() })
        case .notRegistered: ("啟用", { await collector.register() })
        case .requiresApproval: ("打開「登入項目」設定", { collector.openLoginItems() })
        case .enabled: ("停用", { await collector.disable() })
        }
    }
}
