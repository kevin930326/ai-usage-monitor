import Foundation
import Testing
@testable import UsageKit

// 與收集器實際輸出相同的結構
let sampleJSON = """
{
  "schema_version": 1,
  "updated_at": "2026-10-20T16:36:08Z",
  "providers": {
    "codex": {
      "plan": "Team", "error": null,
      "windows": [
        { "id": "five_hour", "label": "5 小時", "used_pct": 0.0, "resets_at": "2026-10-20T21:36:08Z", "hidden": false },
        { "id": "weekly", "label": "每週", "used_pct": 2.0, "resets_at": "2026-10-27T09:45:11Z", "hidden": false }
      ]
    },
    "claude": {
      "plan": "Max", "error": null,
      "windows": [
        { "id": "five_hour", "label": "5 小時", "used_pct": 24.0, "resets_at": "2026-10-20T19:00:00Z", "hidden": false },
        { "id": "weekly", "label": "每週", "used_pct": 9.0, "resets_at": "2026-10-20T23:00:00Z", "hidden": false },
        { "id": "weekly_fable", "label": "每週 Fable", "used_pct": 95.0, "resets_at": "2026-10-20T23:00:00Z", "hidden": true }
      ]
    }
  }
}
"""

@Suite struct DecodingTests {
    @Test func decodesCollectorOutput() throws {
        let snap = try UsageDecoder.decode(Data(sampleJSON.utf8))
        #expect(snap.schemaVersion == 1)
        #expect(snap.providers["claude"]?.plan == "Max")
        #expect(snap.providers["claude"]?.windows.count == 3)
        #expect(snap.providers["claude"]?.visibleWindows.map(\.id) == ["five_hour", "weekly"])
        #expect(snap.updatedAt == ISO8601DateFormatter().date(from: "2026-10-20T16:36:08Z"))
    }

    @Test func missingHiddenDefaultsToFalse() throws {
        let json = """
        {"schema_version":1,"updated_at":"2026-10-20T00:00:00Z","providers":{"claude":{"plan":null,"error":null,
         "windows":[{"id":"weekly","label":"每週","used_pct":1,"resets_at":null}]}}}
        """
        let snap = try UsageDecoder.decode(Data(json.utf8))
        #expect(snap.providers["claude"]?.windows.first?.hidden == false)
        #expect(snap.providers["claude"]?.windows.first?.resetsAt == nil)
    }

    @Test func rejectsUnsupportedSchema() {
        let json = #"{"schema_version":99,"updated_at":"x","providers":{}}"#
        #expect(throws: UsageDecodingError.unsupportedSchema(99)) {
            try UsageDecoder.decode(Data(json.utf8))
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: UsageDecodingError.malformed) {
            try UsageDecoder.decode(Data("not json".utf8))
        }
    }
}

@Suite struct DisplayTests {
    let snap = try! UsageDecoder.decode(Data(sampleJSON.utf8))

    @Test func providersAreOrderedClaudeFirst() {
        #expect(snap.orderedProviderKeys == ["claude", "codex"])
    }

    @Test func tightestIgnoresHiddenWindows() {
        // weekly_fable 用了 95% 但為 hidden，不算
        let tightest = snap.tightestWindow
        #expect(tightest?.provider == "claude")
        #expect(tightest?.window.id == "five_hour")
    }

    @Test func tightestSkipsProvidersWithErrors() {
        var s = snap
        s.providers["claude"]?.error = "尚未登入"
        #expect(s.tightestWindow?.provider == "codex")
        #expect(s.tightestWindow?.window.id == "weekly")
    }

    @Test(arguments: [
        (100.0, UsageSeverity.normal), (51.0, .normal), (50.0, .normal),
        (20.0, .normal), (19.9, .critical), (0.0, .critical),
    ])
    func severityThresholds(remaining: Double, expected: UsageSeverity) {
        #expect(UsageSeverity(remainingPct: remaining) == expected)
    }

    @Test func remainingIsClamped() {
        #expect(UsageWindow(id: "a", label: "a", usedPct: 130).remainingPct == 0)
    }

    @Test func staleAfterThirtyMinutes() {
        #expect(!snap.isStale(now: snap.updatedAt.addingTimeInterval(29 * 60)))
        #expect(snap.isStale(now: snap.updatedAt.addingTimeInterval(31 * 60)))
    }

    @Test func watchStaleAfterFortyFiveMinutes() {
        // 手錶背景更新約每 30 分鐘、常會延後：35 分鐘還不算過期，iPhone 與 Mac 已過期
        let at35 = snap.updatedAt.addingTimeInterval(35 * 60)
        #expect(snap.isStale(now: at35))
        #expect(!snap.isStale(now: at35, after: UsageSnapshot.watchStaleAfter))
        #expect(!snap.isStale(now: snap.updatedAt.addingTimeInterval(44 * 60), after: UsageSnapshot.watchStaleAfter))
        #expect(snap.isStale(now: snap.updatedAt.addingTimeInterval(46 * 60), after: UsageSnapshot.watchStaleAfter))
    }

    @Test func displayNames() {
        #expect(ProviderInfo.displayName("claude") == "Claude")
        #expect(ProviderInfo.displayName("cursor") == "Cursor")
    }
}
