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
