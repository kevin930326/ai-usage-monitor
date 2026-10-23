import AppKit
import SwiftUI
import UserNotifications
import UsageKit

/// 額度通知（FR-19、ADR-0008 第 5 節）：剩不到 20%、用得太快、額度重置。
/// 事件判斷在 UsageKit（`QuotaAlerts`）；這裡保存送過的鍵（UserDefaults）、依開關送出，並在點通知時打開面板。
/// 送過的鍵不論開關都記錄：打開開關時不會補送已經發生的事件，「重置」也需要知道這一輪曾經剩不到 20%。
@MainActor
final class QuotaNotifier: NSObject {
    static let shared = QuotaNotifier()

    private static let sentKey = "notify.sent"
    private let defaults = UserDefaults.standard

    /// Debug 的截圖與量測（假資料）不送通知、不改記錄
    private var disabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["AUM_DEMO_PANEL"] == "1" || ProcessInfo.processInfo.environment["AUM_RENDER_DIR"] != nil
        #else
        false
        #endif
    }

    /// 通知中心需要 App 的 bundle（`swift run` 之類的執行方式沒有）
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard !disabled else { return }
        center?.delegate = self
    }

    /// 每次讀到新的快照、以及每分鐘呼叫（重置時間到了也要判斷）
    func evaluate(snapshot: UsageSnapshot?, now: Date) {
        guard !disabled, let snapshot else { return }
        let sent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        let alerts = QuotaAlerts.detect(snapshot: snapshot, now: now, sent: sent)
        guard !alerts.isEmpty else { return }
        let updated = QuotaAlerts.pruned(sent.union(alerts.map(\.key)), now: now)
        defaults.set(Array(updated).sorted(), forKey: Self.sentKey)
        let settings = PanelSettings.shared
        for alert in alerts where settings.notifies(alert.kind) {
            deliver(alert)
        }
    }

    private func deliver(_ alert: QuotaAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.provider
        content.userInfo = ["card": alert.cardID]
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        center.add(request) { error in
            if let error { UsageStore.log("notification failed: \(type(of: error))") }
        }
        UsageStore.log("notified \(alert.kind.rawValue) \(alert.provider)/\(alert.windowID)")
    }

    /// 打開任一個開關時向系統要求權限；回傳目前是否允許
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            UsageStore.log("notification authorization failed: \(type(of: error))")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// 系統設定的通知頁
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension QuotaNotifier: UNUserNotificationCenterDelegate {
    /// App 在前景（面板開著）時也顯示橫幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// 點通知：打開面板，對應的卡片亮一下（ADR-0010 第四階段）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let card = response.notification.request.content.userInfo["card"] as? String
        await MainActor.run {
            AppActions.openPanel(highlight: card)
        }
    }
}

/// 設定的「通知」：三個開關，預設關（FR-19）。打開時才向系統要求權限；被拒絕時說明到哪裡打開。
struct NotificationSettingsSection: View {
    @Environment(PanelSettings.self) private var settings
    /// 截圖時不查詢通知權限
    var interactive = true

    @State private var status: UNAuthorizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("通知").font(.headline)
            SwitchRow(title: "剩不到 20%", detail: "任一額度剩不到 20% 時通知一次（每一輪一次）", isOn: binding(\.notifyLow))
            SwitchRow(title: "用得太快", detail: "照目前速度會在重置前用完時通知一次", isOn: binding(\.notifyTooFast))
            SwitchRow(title: "額度重置", detail: "曾經剩不到 20% 的額度重置後通知一次", isOn: binding(\.notifyReset))
            if status == .denied, settings.notifiesAnything {
                HStack(spacing: 8) {
                    Text("系統不允許「AI 用量」發出通知。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打開通知設定", action: QuotaNotifier.openSystemSettings)
                        .buttonStyle(PanelPillButtonStyle())
                }
            } else {
                Text("點通知會打開面板並標出對應的卡片。通知只由這台 Mac 發出，不經過網路。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard interactive else { return }
            status = await QuotaNotifier.shared.authorizationStatus()
        }
        // 使用者可能在系統設定裡改過
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard interactive else { return }
            Task { status = await QuotaNotifier.shared.authorizationStatus() }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<PanelSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { isOn in
            settings[keyPath: keyPath] = isOn
            guard isOn, interactive else { return }
            Task {
                _ = await QuotaNotifier.shared.requestAuthorization()
                status = await QuotaNotifier.shared.authorizationStatus()
            }
        })
    }
}
