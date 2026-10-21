import Foundation
import Testing
@testable import UsageKit

/// 只用 Claude 或只用 Codex 的使用者：收集器沒有啟用的服務不在 `providers` 裡，這不是錯誤。
@Suite struct OptionalProvidersTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func decode(_ providers: String) throws -> UsageSnapshot {
        let json = #"{"schema_version": 1, "updated_at": "2027-01-15T08:00:00Z", "providers": {\#(providers)}}"#
        return try UsageDecoder.decode(Data(json.utf8))
    }

    let codexOnly = #""codex": {"plan": "Plus", "error": null, "windows": [{"id": "five_hour", "label": "5 小時", "used_pct": 30, "resets_at": "2027-01-15T10:00:00Z", "hidden": false}, {"id": "weekly", "label": "每週", "used_pct": 70, "resets_at": "2027-01-20T10:00:00Z", "hidden": false}]}"#

    @Test func singleProviderDecodesWithoutError() throws {
        let snapshot = try decode(codexOnly)
        #expect(snapshot.orderedProviderKeys == ["codex"])
        #expect(!snapshot.hasNoProviders)
        let tightest = try #require(snapshot.tightestWindow(at: now))
        #expect(tightest.provider == "codex")
        #expect(tightest.window.id == "weekly")
    }

    @Test func singleProviderActivityStateIsNotPartialFailure() throws {
        let state = UsageActivityState(snapshot: try decode(codexOnly), mode: .remaining)
        #expect(state.providers.map(\.key) == ["codex"])
        #expect(!state.hasPartialFailure)
        #expect(try state.encodedSize() < UsageActivityState.maxEncodedBytes)
    }

    @Test func noProvidersIsValidAndEmpty() throws {
        let snapshot = try decode("")
        #expect(snapshot.hasNoProviders)
        #expect(snapshot.tightestWindow(at: now) == nil)
        let state = UsageActivityState(snapshot: snapshot, mode: .remaining)
        #expect(state.providers.isEmpty)
        #expect(state.tightest(at: now) == nil)
        #expect(!state.hasPartialFailure)
    }
}
