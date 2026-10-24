import XCTest
@testable import UsageKit

final class SetupChecklistTests: XCTestCase {
    private func inputs(claude: ProviderSetupInput = .init(), codex: ProviderSetupInput = .init(),
                        inApplications: Bool = true, collectorNeedsAction: Bool = false,
                        notifications: Bool? = nil, loginItem: Bool = false, relay: Bool = false) -> SetupInputs {
        SetupInputs(appInApplications: inApplications, collectorNeedsAction: collectorNeedsAction, claude: claude, codex: codex,
                    notificationsAllowed: notifications, loginItemEnabled: loginItem, relayConfigured: relay)
    }

    func testOnlyOneProviderNeeded() {
        let i = inputs(claude: .init(login: .enabled), codex: .init(login: .notInstalled))
        XCTAssertEqual(SetupChecklist.status(of: .claude, i), .done)
        XCTAssertEqual(SetupChecklist.status(of: .codex, i), .optional)
        XCTAssertEqual(SetupChecklist.commands(for: .codex, i), ["npm install -g @openai/codex", "codex login"])
        XCTAssertEqual(SetupChecklist.commands(for: .claude, i), [])
    }

    func testNeitherProviderUsableNeedsBoth() {
        let i = inputs(claude: .init(login: .notInstalled), codex: .init(login: .notInstalled))
        XCTAssertEqual(SetupChecklist.status(of: .claude, i), .needsAction)
        XCTAssertEqual(SetupChecklist.status(of: .codex, i), .needsAction)
        // 開發版沒有偵測結果、也沒有資料：同樣兩個都要處理
        let dev = inputs()
        XCTAssertEqual(SetupChecklist.status(of: .claude, dev), .needsAction)
    }

    func testLoginStates() {
        let notLogged = inputs(claude: .init(login: .notLoggedIn), codex: .init(login: .apiKey))
        XCTAssertEqual(SetupChecklist.status(of: .claude, notLogged), .needsAction)
        XCTAssertEqual(SetupChecklist.commands(for: .claude, notLogged), ["claude auth login"])
        XCTAssertEqual(SetupChecklist.status(of: .codex, notLogged), .needsAction)
        XCTAssertEqual(SetupChecklist.commands(for: .codex, notLogged), ["codex logout", "codex login"])
        let unknown = inputs(claude: .init(login: .unknown), codex: .init(collecting: true))
        XCTAssertEqual(SetupChecklist.status(of: .claude, unknown), .needsAction)
        XCTAssertEqual(SetupChecklist.status(of: .codex, unknown), .done)
    }

    func testCollectingDataCountsAsDoneEvenWithoutDetection() {
        // 開發版：沒有偵測結果，只看 usage.json
        let i = inputs(claude: .init(collecting: true), codex: .init(collectError: "尚未登入 Codex CLI"))
        XCTAssertEqual(SetupChecklist.status(of: .claude, i), .done)
        XCTAssertEqual(SetupChecklist.status(of: .codex, i), .needsAction)
        XCTAssertEqual(SetupChecklist.commands(for: .codex, i), ["codex login"])
        XCTAssertTrue(SetupChecklist.providerDetail(.codex, i).contains("尚未登入"))
    }

    func testLatestExplicitDetectionBeatsOldData() {
        // 收集成功後登出、或改用 API key：最新的偵測結果優先
        let i = inputs(claude: .init(login: .notLoggedIn, collecting: true), codex: .init(login: .apiKey, collecting: true))
        XCTAssertEqual(SetupChecklist.status(of: .claude, i), .needsAction)
        XCTAssertEqual(SetupChecklist.commands(for: .claude, i), ["claude auth login"])
        XCTAssertFalse(SetupChecklist.providerDetail(.claude, i).contains("正在收集"))
        XCTAssertEqual(SetupChecklist.status(of: .codex, i), .needsAction)
        XCTAssertEqual(SetupChecklist.commands(for: .codex, i), ["codex logout", "codex login"])
        // 偵測「不知道」時，還沒過期的資料可以當作可用
        let unknown = inputs(claude: .init(login: .unknown, collecting: true))
        XCTAssertEqual(SetupChecklist.status(of: .claude, unknown), .done)
        // 沒安裝但收集器在別的路徑照樣收集到：以資料為準
        let elsewhere = inputs(claude: .init(login: .notInstalled, collecting: true))
        XCTAssertEqual(SetupChecklist.status(of: .claude, elsewhere), .done)
        // 沒安裝而且收集失敗：給安裝指令
        let missing = inputs(claude: .init(login: .notInstalled, collectError: "找不到 claude 執行檔"), codex: .init(collecting: true))
        XCTAssertEqual(SetupChecklist.status(of: .claude, missing), .optional)
        XCTAssertEqual(SetupChecklist.commands(for: .claude, missing).first, "curl -fsSL https://claude.ai/install.sh | bash")
    }

    func testOtherSteps() {
        var i = inputs(inApplications: false, collectorNeedsAction: true)
        XCTAssertEqual(SetupChecklist.status(of: .location, i), .needsAction)
        XCTAssertEqual(SetupChecklist.status(of: .collector, i), .needsAction)
        XCTAssertEqual(SetupChecklist.status(of: .notifications, i), .optional)
        XCTAssertEqual(SetupChecklist.status(of: .loginItem, i), .optional)
        XCTAssertEqual(SetupChecklist.status(of: .iphone, i), .optional)
        i = inputs(notifications: true, loginItem: true, relay: true)
        for step in [SetupStepID.location, .collector, .notifications, .loginItem, .appearance, .iphone] {
            XCTAssertEqual(SetupChecklist.status(of: step, i), .done, step.rawValue)
        }
    }

    func testShowsAutomaticallyOnlyForNewInstalls() {
        XCTAssertTrue(SetupChecklist.showsAutomatically(completed: false, hasUsageData: false))
        XCTAssertFalse(SetupChecklist.showsAutomatically(completed: false, hasUsageData: true))
        XCTAssertFalse(SetupChecklist.showsAutomatically(completed: true, hasUsageData: false))
    }

    func testProviderStatesMatchCollectorStrings() {
        for raw in ["enabled", "not_logged_in", "api_key", "not_installed", "unknown"] {
            XCTAssertNotNil(ProviderLoginState(rawValue: raw), raw)
        }
    }
}
