import Foundation
import UserNotifications
import UsageKit

/// AI 狀態的系統通知（mascot2 第 2 部分）：需要你超過設定的秒數、跑超過設定分鐘數的任務完成。
/// 判斷在 UsageKit（`AgentSessions.notices`）；這裡只去重、檢查靜音與勿擾、送出。
/// 通知中心會把內容存到磁碟，所以內容只有 AI 與種類：不含資料夾名稱、工作階段 ID 或任何對話內容。
/// 專注模式由系統處理（通知中心本來就遵守）。
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    /// 發過的（工作階段＋狀態＋進入時間）；只放記憶體，工作階段消失就清掉
    private var sent: Set<String> = []

    /// Debug 的截圖與量測（假資料）不送通知
    private var disabled: Bool {
        #if DEBUG
        DebugTools.isDemo || ProcessInfo.processInfo.environment["AUM_RENDER_DIR"] != nil
        #else
        false
        #endif
    }

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// 狀態變了、或到了下一次檢查的時間：送出該發而還沒發的。靜音、勿擾時照樣記成發過（結束後不補發）
    func evaluate(_ sessions: AgentSessions, at now: Int64) {
        let settings = PanelSettings.shared
        let notices = sessions.notices(at: now, policy: settings.agentNoticePolicy)
        let fresh = notices.filter { !sent.contains($0.key) }
        // 只留現在還成立的鍵：處理了、看過了、工作階段結束的不必記著
        sent = Set(notices.map(\.key))
        guard !fresh.isEmpty, !disabled, !settings.isMascotQuiet(at: Date(timeIntervalSince1970: Double(now) / 1000)) else { return }
        for notice in fresh { deliver(notice) }
    }

    private func deliver(_ notice: AgentNotice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        let name = notice.ai == .claude ? "Claude Code" : "Codex"
        switch notice.kind {
        case .needsYou:
            content.title = "\(name) 需要你"
            content.body = switch notice.need {
            case .permission: "等你允許一個動作"
            case .question: "有問題等你回答"
            case .plan: "計畫等你確認"
            default: "等你處理"
            }
        case .done:
            content.title = "\(name) 完成了"
            content.body = "跑了 \(PanelSettings.shared.agentLongTaskMinutes) 分鐘以上的任務完成了"
        }
        content.threadIdentifier = "agent"
        content.userInfo = ["agent": true]
        // 識別碼不帶工作階段：通知中心的資料庫裡只有隨機值
        let request = UNNotificationRequest(identifier: "agent-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { UsageStore.log("notification failed: \(type(of: error))") }
        }
        UsageStore.log("notified agent \(notice.kind.rawValue) \(notice.ai.rawValue)")
    }
}
