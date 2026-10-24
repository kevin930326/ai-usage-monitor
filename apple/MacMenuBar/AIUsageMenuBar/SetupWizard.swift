import AppKit
import SwiftUI
import UserNotifications
import UsageKit
import UsageKitUI

/// 首次設定精靈（FR-54、ADR-0013）：只列出 App 自動化不了的步驟，每一步顯示狀態（完成／需要處理／可選），
/// 缺什麼就給終端機指令與「複製」。判斷規則在 UsageKit 的 `SetupChecklist`（有單元測試）。
///
/// 第一次打開、而且還沒有任何資料（usage.json 不存在）時自動顯示；已經在用的人不會被打擾，
/// 從設定 › 一般 ›「重新執行設定精靈」打開。不讀憑證或密鑰：服務的登入狀態來自內建收集器的
/// `usage_collector.setup --json --dry-run`（只有狀態字串），中繼只看 config.json 有沒有網址。
@Observable
@MainActor
final class SetupWizardModel {
    static let shared = SetupWizardModel()

    private(set) var inputs: SetupInputs
    /// 通知權限的原始狀態（「允許通知」與「打開通知設定」用）
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var checking = false

    init(inputs: SetupInputs = SetupWizardModel.placeholder, notificationStatus: UNAuthorizationStatus = .notDetermined) {
        self.inputs = inputs
        self.notificationStatus = notificationStatus
    }

    static let placeholder = SetupInputs(appInApplications: true, collectorNeedsAction: false, claude: .init(), codex: .init(),
                                         notificationsAllowed: nil, loginItemEnabled: false, relayConfigured: false)

    // MARK: - 檢查

    func refresh() async {
        checking = true
        defer { checking = false }
        let collector = CollectorService.shared
        await collector.refresh()
        let updatesConfig = collector.state == .enabled
        let detected = await collector.detectProviders(updatingConfig: updatesConfig)
        UsageStore.shared.reload()
        let snapshot = UsageStore.shared.snapshot
        func provider(_ key: String, _ login: ProviderLoginState?) -> ProviderSetupInput {
            let usage = snapshot?.providers[key]
            // 過期的快照（收集器停了）不算正在收集
            let fresh = snapshot.map { !$0.isStale(now: RenderClock.now) } ?? false
            let collecting = fresh && (usage.map { $0.error == nil && !$0.windows.isEmpty } ?? false)
            return ProviderSetupInput(login: login, collecting: collecting, collectError: usage?.error)
        }
        notificationStatus = await QuotaNotifier.shared.authorizationStatus()
        inputs = SetupInputs(
            appInApplications: Self.appInApplications,
            collectorNeedsAction: collector.needsAction,
            claude: provider("claude", detected?.claude),
            codex: provider("codex", detected?.codex),
            notificationsAllowed: Self.allowed(notificationStatus),
            loginItemEnabled: LoginItemSection.isEnabled,
            relayConfigured: Self.relayConfigured,
            detectionUpdatedConfig: updatesConfig
        )
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool? {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        case .denied: false
        case .notDetermined: nil
        @unknown default: nil
        }
    }

    /// 與 CollectorService 相同的規則：`/Applications` 或 `~/Applications`，不是 App Translocation 的暫時位置
    private static var appInApplications: Bool {
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") { return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AUM_TEST_AGENT"] == "1" { return true }
        #endif
        let parent = url.deletingLastPathComponent().path
        return parent == "/Applications" || parent == "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications"
    }

    /// 只看 config.json 有沒有中繼網址；密鑰在 Keychain，App 不讀
    private static var relayConfigured: Bool {
        let url = UsageStore.shared.locator.directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relay = object["relay_url"] as? String else { return false }
        return !relay.isEmpty
    }

    // MARK: - 打開與完成

    /// 選單列圖示出現時呼叫：沒有按過「完成」、也還沒有 usage.json 時打開精靈。
    /// 測試、截圖與量測（設定了 AI_USAGE_MONITOR_HOME）不自動打開
    static func openIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        var testing = !(env[UsageFileLocator.homeEnvironmentKey] ?? "").isEmpty
        #if DEBUG
        if env["AUM_TEST_AGENT"] == "1" { testing = false }
        #endif
        guard !testing else { return }
        let hasData = FileManager.default.fileExists(atPath: UsageStore.shared.locator.usageFile.path)
        guard SetupChecklist.showsAutomatically(completed: UserDefaults.standard.bool(forKey: SetupChecklist.completedKey),
                                                hasUsageData: hasData) else { return }
        UsageStore.log("setup wizard: first launch without data, opening")
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            AppActions.openWizard?()
        }
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: SetupChecklist.completedKey)
    }

    func requestNotifications() async {
        _ = await QuotaNotifier.shared.requestAuthorization()
        await refresh()
    }
}

struct SetupWizardView: View {
    static let windowID = "setup-wizard"

    let model: SetupWizardModel
    /// 截圖時不執行檢查、不用捲動視圖（ImageRenderer 畫不出 AppKit 的捲動視圖）
    var interactive = true

    @Environment(PanelSettings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Environment(CollectorService.self) private var collector

    /// 背景收集器的狀態直接看 CollectorService（在精靈裡按「啟用」等之後立即反映在標記與步數，不必重新檢查）
    private var inputs: SetupInputs {
        var inputs = model.inputs
        inputs.collectorNeedsAction = collector.needsAction
        return inputs
    }
    private var collectorState: CollectorService.State { collector.state }

    var body: some View {
        Group {
            if interactive {
                VStack(spacing: 0) {
                    ScrollView { content }
                    Divider()
                    footer
                }
                .frame(width: 540)
                .frame(minHeight: 560, idealHeight: 720)
            } else {
                VStack(spacing: 0) {
                    content
                    Divider()
                    footer
                }
                .frame(width: 540)
            }
        }
        .task { if interactive { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 從終端機登入、在系統設定按完回來時重新檢查
            if interactive { Task { await model.refresh() } }
        }
        // 換外觀時與面板相同的過渡；減少動態效果時直接換（FR-51）
        .animation(interactive && !reduceMotion ? PanelTiming.colorScheme : nil, value: colorScheme)
    }

    private var remaining: Int {
        SetupStepID.allCases.filter { SetupChecklist.status(of: $0, inputs) == .needsAction }.count
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("設定 AI 用量").font(.title2.weight(.semibold))
                Text(remaining == 0 ? "都設定好了。之後可以在設定 › 一般 › 重新執行設定精靈。"
                                    : "還有 \(remaining) 步要你自己處理，其他都已經自動完成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(SetupStepID.allCases.enumerated()), id: \.element) { index, step in
                StepCard(number: index + 1, step: step, status: SetupChecklist.status(of: step, inputs)) {
                    stepContent(step)
                }
            }
        }
        .padding(22)
    }

    private var footer: some View {
        HStack {
            Button(model.checking ? "檢查中…" : "重新檢查") { Task { await model.refresh() } }
                .buttonStyle(PanelPillButtonStyle())
                .disabled(model.checking)
            Spacer()
            Button("完成") {
                model.complete()
                dismissWindow(id: Self.windowID)
            }
            .buttonStyle(PanelPillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func stepContent(_ step: SetupStepID) -> some View {
        switch step {
        case .location:
            if inputs.appInApplications {
                DetailText("App 在「應用程式」資料夾。")
            } else {
                DetailText("從 .dmg 或「下載」直接打開時，macOS 會把 App 放在暫時的位置，背景收集器之後會失效。把「AI 用量」拖到「應用程式」資料夾，再從那裡打開。第一次打開被擋下時，到「系統設定 › 隱私權與安全性」按「強制打開」。")
                Button("打開「應用程式」資料夾") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                    .buttonStyle(PanelPillButtonStyle())
            }
        case .collector:
            if collectorState == .needsApplicationsFolder {
                // 與第 1 步同一件事，不重複說明
                DetailText("完成第 1 步、從「應用程式」打開後會自動啟用，每 5 分鐘收集一次。")
            } else {
                CollectorSettingsSection(interactive: interactive, inWizard: true)
            }
        case .claude, .codex:
            DetailText(SetupChecklist.providerDetail(step, inputs))
            ForEach(SetupChecklist.commands(for: step, inputs), id: \.self) { CommandRow(command: $0) }
        case .notifications:
            switch model.notificationStatus {
            case .denied:
                DetailText("通知被關掉了。要在剩不到 20% 時收到通知，到系統設定打開。")
                Button("打開通知設定") { QuotaNotifier.openSystemSettings() }
                    .buttonStyle(PanelPillButtonStyle())
            case .notDetermined:
                DetailText("額度剩不到 20% 時通知你（可以在設定調整）。")
                Button("允許通知") { Task { await model.requestNotifications() } }
                    .buttonStyle(PanelPillButtonStyle())
            default:
                DetailText("已允許。額度剩不到 20% 時通知你，可以在設定調整。")
            }
        case .loginItem:
            if interactive {
                LoginItemSection(inWizard: true) { Task { await model.refresh() } }
            } else {
                // 截圖：開關照假資料畫（LoginItemSection 在截圖時一律是「沒有登記」）
                SwitchRow(title: "登入 Mac 後自動在選單列顯示用量", isOn: .constant(inputs.loginItemEnabled))
            }
        case .appearance:
            FlowChips(choices: AppearanceChoice.allCases.map { ($0, $0.title) }, selected: settings.appearance) {
                settings.appearance = $0
            }
            DetailText("套用到面板、設定、完整統計與這個視窗。選單列圖示跟隨選單列本身的深淺色。")
        case .iphone:
            if inputs.relayConfigured {
                DetailText("中繼已設定，iPhone App 配對後就會顯示用量。安裝與配對見 README 的「1. 加上 iPhone」。")
            } else {
                DetailText("需要你自己的中繼（Cloudflare 免費方案）與 iPhone App。不接也可以，Mac 上照常顯示。步驟見 README 的「1. 加上 iPhone」。")
            }
            Button("打開說明") { NSWorkspace.shared.open(Self.iPhoneGuide) }
                .buttonStyle(PanelPillButtonStyle())
        }
    }

    /// 說明在 GitHub 上（用瀏覽器打開，App 本身不連網）
    static let iPhoneGuide = URL(string: "https://github.com/kevin930326/ai-usage-monitor#1-加上-iphone")!
}

/// 一步：狀態圖示＋編號標題＋內容
private struct StepCard<Content: View>: View {
    let number: Int
    let step: SetupStepID
    let status: SetupStepStatus
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .font(.title3)
                .accessibilityLabel(icon.label)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(number). \(step.title)").font(.headline)
                    Spacer(minLength: 8)
                    Text(icon.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status == .needsAction ? UsageColors.notice : .secondary)
                }
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var icon: (name: String, color: Color, label: String) {
        switch status {
        case .done: ("checkmark.circle.fill", .green, "完成")
        case .needsAction: ("exclamationmark.circle.fill", UsageColors.notice, "需要處理")
        case .optional: ("circle.dashed", .secondary, "可選")
        }
    }
}

private struct DetailText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 終端機指令＋「複製」
private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "已複製" : "複製") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .buttonStyle(PanelPillButtonStyle())
            .accessibilityLabel(copied ? "已複製" : "複製指令 \(command)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
