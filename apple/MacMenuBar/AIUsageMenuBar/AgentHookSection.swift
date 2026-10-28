import SwiftUI
import UsageKit

/// 設定的「AI 狀態」（ADR-0017 第 3 節）：連接 Claude Code／Codex 的 hook，讓角色知道確切狀態
struct AgentHookSection: View {
    @State private var installer = AgentHookInstaller.shared
    @Environment(PanelSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 狀態").font(.headline)
            Text("連接後，Claude Code 與 Codex 每到一個時間點（開始、送出提示、執行工具、需要你、完成）會通知這個 App，角色就知道哪個 AI 在工作、哪個在等你。只傳事件種類、工作階段的雜湊與資料夾名稱，不傳提示、指令或檔案內容；資料夾名稱只顯示在瀏海上，不存檔、不上傳。沒連接時照紀錄檔的修改時間猜。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentKind.allCases, id: \.self) { ai in
                row(ai)
            }
            Text("需要你時通知").font(.subheadline.weight(.semibold)).padding(.top, 4)
            FlowChips(choices: PanelSettings.needsYouSecondChoices.map { ($0, $0 == 0 ? "關閉" : "\($0) 秒後") },
                      selected: settings.agentNeedsYouSeconds) { settings.agentNeedsYouSeconds = $0 }
            Text("長任務完成時通知").font(.subheadline.weight(.semibold)).padding(.top, 4)
            FlowChips(choices: PanelSettings.longTaskMinuteChoices.map { ($0, $0 == 0 ? "關閉" : "跑超過 \($0) 分鐘") },
                      selected: settings.agentLongTaskMinutes) { settings.agentLongTaskMinutes = $0 }
            Text("走系統通知中心，會遵守專注模式；瀏海右鍵的靜音與勿擾也會擋掉。通知只寫哪個 AI、要你做什麼，不寫資料夾名稱（通知中心會把通知存在磁碟上）。瀏海上的外框、舉手與揮手不受這兩個設定影響。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SwitchRow(title: "等你下指令時瀏海輕輕脈動",
                      detail: "AI 做完、等你下一個指令時，收著的瀏海每 7 秒亮一下外框，不用展開就知道。靜音、勿擾或角色動畫「關閉」時不脈動",
                      isOn: $settings.notchWaitingPulse)
        }
        .onAppear { installer.refresh() }
    }

    private func row(_ ai: AgentKind) -> some View {
        let state = installer.states[ai] ?? .notInstalled
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ai == .claude ? "Claude Code" : "Codex").font(.body)
                    Text(summary(state)).font(.caption).foregroundStyle(state == .installed ? Color.secondary : Color.orange)
                }
                Spacer()
                switch state {
                case .notInstalled:
                    Button("連接") { installer.connect(ai) }
                case .needsRepair:
                    Button("修好") { installer.connect(ai) }
                    Button("移除") { installer.disconnect(ai) }
                case .installed:
                    Button("移除") { installer.disconnect(ai) }
                case .unreadable:
                    EmptyView()
                }
            }
            Text("會改 \(installer.displayPath(for: ai))：在 \(events(ai)) 加上這個 App 的 hook。改之前先備份原檔；只加、只刪自己的項目，其他 App 的 hook 照樣保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if ai == .codex && state != .notInstalled {
                Label(installer.codexDisabled
                      ? "Codex 的 config.toml 有 [features] hooks = false，hook 不會執行。"
                      : "第一次連接或修好後，在 Codex 裡執行 /hooks 信任這個 hook 才會生效。",
                      systemImage: "info.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = installer.message[ai] {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ state: AgentHookInstaller.State) -> String {
        switch state {
        case .notInstalled: "沒有連接"
        case .installed: "已連接"
        case .needsRepair(let missing, let wrongPath):
            wrongPath ? "App 被移動過，hook 指向舊的位置，需要修好" : "少了 \(missing.count) 個事件，需要修好"
        case .unreadable: "設定檔不是合法的 JSON，沒辦法連接；修好檔案後再打開設定"
        }
    }

    private func events(_ ai: AgentKind) -> String {
        AgentHookEvent.installed(for: ai).map(\.rawValue).joined(separator: "、")
    }
}
