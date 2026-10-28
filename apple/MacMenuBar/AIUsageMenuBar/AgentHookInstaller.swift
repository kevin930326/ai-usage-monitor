import Foundation
import Observation
import UsageKit

/// 設定裡的「連接 Claude Code／Codex」（ADR-0017 第 3 節）：決定設定檔的位置、呼叫 `AgentHookFiles`，把結果給畫面。
/// 測試、示範與截圖時設定檔一律在資料夾裡的假家目錄，不碰真的 `~/.claude`、`~/.codex`。
@MainActor @Observable
final class AgentHookInstaller {
    static let shared = AgentHookInstaller()

    enum State: Equatable {
        case notInstalled
        case installed
        case needsRepair(missing: [AgentHookEvent], wrongPath: Bool)
        /// 設定檔不是合法 JSON 或形狀不對：不改，只提示
        case unreadable
    }

    private(set) var states: [AgentKind: State] = [:]
    /// Codex 的 `config.toml` 把 hook 關掉了
    private(set) var codexDisabled = false
    /// 上一次按鈕的結果（給畫面顯示；不寫日誌）
    private(set) var message: [AgentKind: String] = [:]

    /// 測試、示範、截圖：用資料夾裡的假家目錄
    var home: URL {
        var testing = UsageFileLocator.isTestEnvironment() || UsageStore.shared.usesCustomHome
        #if DEBUG
        testing = testing || DebugTools.isDemo
        #endif
        return testing ? UsageStore.shared.locator.directory : FileManager.default.homeDirectoryForCurrentUser
    }

    /// 各 AI 的設定檔（畫面顯示時把家目錄寫成 ~）
    func file(for ai: AgentKind) -> URL {
        switch ai {
        case .claude: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        }
    }

    func displayPath(for ai: AgentKind) -> String {
        switch ai {
        case .claude: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        }
    }

    /// hook 程式在 App 包裡的位置；App 被移動時會變，狀態因此變成「需要修好」
    var command: (AgentKind) -> String {
        let executable = Bundle.main.bundleURL.appendingPathComponent(AgentHookConfig.marker).path
        return { AgentHookConfig.command(executable: executable, ai: $0) }
    }

    /// App 啟動與打開設定時檢查
    func refresh() {
        for ai in AgentKind.allCases {
            do {
                states[ai] = switch try AgentHookFiles.status(file: file(for: ai), ai: ai, command: command(ai)) {
                case .notInstalled: .notInstalled
                case .installed: .installed
                case .needsRepair(let missing, let wrongPath): .needsRepair(missing: missing, wrongPath: wrongPath)
                }
            } catch {
                states[ai] = .unreadable
            }
        }
        let toml = try? Data(contentsOf: home.appendingPathComponent(".codex/config.toml"))
        codexDisabled = AgentHookFiles.codexHooksDisabled(configTOML: toml)
    }

    /// 連接或修好
    func connect(_ ai: AgentKind) {
        do {
            switch try AgentHookFiles.connect(file: file(for: ai), ai: ai, command: command(ai)) {
            case .written(let backup?): message[ai] = "已連接。原本的檔案備份成 \(backup.lastPathComponent)（在設定檔實際所在的資料夾）。"
            case .written(nil): message[ai] = "已連接（新建了這個檔案）。"
            case .unchanged: message[ai] = "已經連接好了，不用改。"
            }
        } catch {
            message[ai] = Self.failure(error)
            UsageStore.log("agent hook connect failed (\(ai.rawValue))")
        }
        refresh()
    }

    /// 移除：只刪我們的項目
    func disconnect(_ ai: AgentKind) {
        do {
            switch try AgentHookFiles.disconnect(file: file(for: ai)) {
            case .written(let backup?): message[ai] = "已移除。原本的檔案備份成 \(backup.lastPathComponent)。"
            case .written(nil), .unchanged: message[ai] = "沒有我們的 hook，不用改。"
            }
        } catch {
            message[ai] = Self.failure(error)
            UsageStore.log("agent hook disconnect failed (\(ai.rawValue))")
        }
        refresh()
    }

    private static func failure(_ error: Error) -> String {
        switch error {
        case AgentHookConfig.ConfigError.invalidJSON:
            "設定檔不是合法的 JSON，沒有修改。修好檔案後再按一次。"
        case AgentHookConfig.ConfigError.unexpectedShape:
            "設定檔的 hooks 格式和預期不同，沒有修改。"
        default:
            "無法寫入設定檔，沒有修改。"
        }
    }
}
