import Testing
@testable import UsageKit

/// 開機後第一次解鎖前被系統在背景啟動時讀不到設定，解鎖後要能補讀回來。
@Suite struct StoredSettingTests {
    @Test func emptyValueIsReloaded() {
        #expect(StoredSetting.reloaded("") { "token" } == "token")
    }

    @Test func stillUnreadableStaysEmpty() {
        #expect(StoredSetting.reloaded("") { nil } == "")
        #expect(StoredSetting.reloaded("") { "" } == "")
    }

    /// 已有值（例如設定畫面剛存的）時不讀、不覆蓋
    @Test func existingValueIsKept() {
        var reads = 0
        let value = StoredSetting.reloaded("saved") {
            reads += 1
            return "stale"
        }
        #expect(value == "saved")
        #expect(reads == 0)
    }
}
