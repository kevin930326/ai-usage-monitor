import Foundation
import Testing
@testable import UsageKit

struct UsageFileLocatorTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func defaultsToApplicationSupport() {
        let locator = UsageFileLocator(environment: [:], homeDirectory: home, testing: false)
        #expect(locator.usageFile.path == "/Users/someone/Library/Application Support/AIUsageMonitor/usage.json")
    }

    @Test func environmentOverridesDirectory() {
        let locator = UsageFileLocator(environment: ["AI_USAGE_MONITOR_HOME": "/tmp/fixture"], homeDirectory: home)
        #expect(locator.usageFile.path == "/tmp/fixture/usage.json")
        #expect(locator.historyFile.path == "/tmp/fixture/history.sqlite3")
    }

    @Test func emptyEnvironmentFallsBack() {
        let locator = UsageFileLocator(environment: ["AI_USAGE_MONITOR_HOME": ""], homeDirectory: home, testing: false)
        #expect(locator.directory.path.hasSuffix("Application Support/AIUsageMonitor"))
    }

    @Test func detectsTestEnvironments() {
        #expect(UsageFileLocator.isTestEnvironment())  // 這個行程就是 swift test
        #expect(UsageFileLocator.isTestEnvironment(["AUM_TESTING": "1"], processName: "AIUsageMenuBar"))
        #expect(UsageFileLocator.isTestEnvironment(["XCTestConfigurationFilePath": "/x"], processName: "AIUsageMenuBar"))
        #expect(UsageFileLocator.isTestEnvironment([:], processName: "swiftpm-testing-helper"))
        #expect(UsageFileLocator.isTestEnvironment([:], processName: "UsageKitPackageTests.xctest"))
        #expect(!UsageFileLocator.isTestEnvironment(["AUM_TESTING": ""], processName: "AIUsageMenuBar"))
        #expect(!UsageFileLocator.isTestEnvironment([:], processName: "AIUsageMenuBar"))
    }

    @Test func explicitFolderIsAllowedWhileTesting() {
        let locator = UsageFileLocator(environment: ["AI_USAGE_MONITOR_HOME": "/tmp/fixture", "AUM_TESTING": "1"],
                                       homeDirectory: home)
        #expect(locator.directory.path == "/tmp/fixture")
    }

    @Test func refusesTheDefaultFolderWhileTesting() async {
        await #expect(processExitsWith: .failure) {
            _ = UsageFileLocator(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        }
    }

    @Test func loadsSnapshotFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schema_version":1,"updated_at":"2026-10-21T03:00:00Z","providers":{"claude":{"plan":"Max","windows":[{"id":"five_hour","label":"5 小時","used_pct":40,"resets_at":"2026-10-21T05:00:00Z"}]}}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("usage.json"))
        let snapshot = try UsageFileLocator(directory: dir).load()
        #expect(snapshot.providers["claude"]?.windows.first?.usedPct == 40)
    }

    @Test func missingFileThrows() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(throws: (any Error).self) { try UsageFileLocator(directory: dir).load() }
    }
}
