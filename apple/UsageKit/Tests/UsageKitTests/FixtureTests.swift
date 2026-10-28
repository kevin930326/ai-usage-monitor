import Foundation
import Testing
@testable import UsageKit

/// 讀 repo 根目錄的 fixtures/usage-sample.json；收集器與中繼的測試讀同一份（fixtures/README.md）。
@Suite struct FixtureTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UsageKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // UsageKit
        .deletingLastPathComponent()   // apple
        .deletingLastPathComponent()   // repo 根目錄
        .appendingPathComponent("fixtures")
    static let url = folder.appendingPathComponent("usage-sample.json")

    static func load(_ name: String) throws -> UsageSnapshot {
        try UsageDecoder.decode(Data(contentsOf: folder.appendingPathComponent(name)))
    }

    let snapshot: UsageSnapshot
    let updatedAt = Date(timeIntervalSince1970: 1_792_551_600) // 2026-10-21T03:00:00Z

    init() throws {
        snapshot = try UsageDecoder.decode(Data(contentsOf: Self.url))
    }

    @Test func decodesEveryField() throws {
        #expect(snapshot.updatedAt == updatedAt)
        let claude = try #require(snapshot.providers["claude"])
        #expect(claude.plan == "Max")
        #expect(claude.error == nil)
        #expect(claude.windows.map(\.id) == ["five_hour", "weekly", "weekly_opus", "weekly_fable"])
        #expect(claude.visibleWindows.map(\.id) == ["five_hour", "weekly"])
        #expect(claude.windows[0].usedPct == 62.5)
        #expect(claude.windows[3].resetsAt == nil)

        let codex = try #require(snapshot.providers["codex"])
        #expect(codex.plan == nil)
        #expect(codex.error == "token 過期，請在 Mac 重新登入 Codex")
        #expect(codex.windows.isEmpty)
    }

    @Test func hiddenWindowsAndFailedServicesAreIgnoredForTightest() {
        // weekly_opus 已用 97% 但隱藏；Codex 失敗
        let tightest = snapshot.tightestWindow(at: updatedAt)
        #expect(tightest?.provider == "claude")
        #expect(tightest?.window.id == "five_hour")
    }

    @Test func resetWindowIsNoLongerTightest() {
        // 03:30Z 重置後 5 小時額度視為 100%，剩餘最少的額度換成每週
        let afterReset = updatedAt.addingTimeInterval(31 * 60)
        #expect(snapshot.tightestWindow(at: afterReset)?.window.id == "weekly")
    }

    @Test func liveActivityStateKeepsThePartialFailure() throws {
        let state = UsageActivityState(snapshot: snapshot, mode: .remaining)
        #expect(state.hasPartialFailure)
        #expect(state.providers.map(\.key) == ["claude", "codex"])
        #expect(try state.encodedSize() < UsageActivityState.maxEncodedBytes)
    }

    @Test func encoderRoundTrips() throws {
        let again = try UsageDecoder.decode(UsageEncoder.encode(snapshot))
        #expect(again == snapshot)
    }

    // MARK: - ADR-0018：預測與事故（選填）

    @Test func decodesForecastAndIncidents() throws {
        let data = try Self.load("usage-forecast-incidents.json")
        let claude = try #require(data.providers["claude"])
        #expect(claude.windows[0].forecast == QuotaForecast(exhaustsAt: updatedAt.addingTimeInterval(40 * 60), urgent: true, faster: 2.1))
        #expect(claude.windows[1].forecast?.faster == nil)
        #expect(claude.incidents == [ServiceIncident(name: "Elevated errors on Claude Code", impact: "major",
                                                     url: "https://status.claude.com/incidents/abc123",
                                                     startedAt: updatedAt.addingTimeInterval(-20 * 60))])
        #expect(claude.incidents?.first?.link?.absoluteString == "https://status.claude.com/incidents/abc123")
        #expect(data.providers["codex"]?.incidents == [])
        #expect(data.providers["codex"]?.windows[0].forecast == nil)
        // 舊的快照沒有這兩個欄位
        #expect(snapshot.providers["claude"]?.incidents == nil)
        #expect(try UsageDecoder.decode(UsageEncoder.encode(data)) == data)
    }

    @Test func badOptionalFieldsAreIgnored() throws {
        let json = #"{"schema_version":1,"updated_at":"2026-10-21T03:00:00Z","providers":{"claude":{"plan":null,"error":null,"#
            + #""windows":[{"id":"five_hour","label":"5 小時","used_pct":1,"resets_at":null,"forecast":{"urgent":"yes"}}],"#
            + #""incidents":"down"}}}"#
        let data = try UsageDecoder.decode(Data(json.utf8))
        #expect(data.providers["claude"]?.windows[0].forecast == nil)
        #expect(data.providers["claude"]?.incidents == nil)
    }

    @Test func incidentLinksOnlyForStatusPages() {
        for bad in ["http://status.claude.com/incidents/x", "https://evil.example/incidents/x", "https://status.claude.com/x",
                    "https://status.claude.com.evil.example/incidents/x", "https://u@status.openai.com/incidents/x",
                    "https://status.openai.com:8443/incidents/x", "javascript:alert(1)"] {
            #expect(ServiceIncident.link(bad) == nil, "\(bad)")
        }
        #expect(ServiceIncident.link("https://status.openai.com/incidents/01J") != nil)
    }

    @Test func snapshotForecastOnPhone() throws {
        let data = try Self.load("usage-forecast-incidents.json")
        let window = try #require(data.providers["claude"]?.windows[1])
        // 沒有歷史：用快照的，緊急與否照現在重算
        let later = updatedAt.addingTimeInterval(30 * 3600)
        #expect(QuotaForecast.current(window: window, provider: "claude", history: nil, stale: false, now: later)?.urgent == true)
        #expect(QuotaForecast.current(window: window, provider: "claude", history: nil, stale: false, now: updatedAt)?.urgent == false)
        #expect(QuotaForecast.current(window: window, provider: "claude", history: nil, stale: true, now: updatedAt) == nil)
        // 預計時間已經過了
        #expect(QuotaForecast.current(window: window, provider: "claude", history: nil, stale: false,
                                      now: updatedAt.addingTimeInterval(31 * 3600)) == nil)
        // 有歷史（Mac）但算不出來：用快照的（同一套規則）；快照也沒有就沒有
        let sparse = QuotaHistory(samples: [QuotaSample(ts: updatedAt, provider: "claude", windowID: "weekly", usedPct: 60,
                                                        resetsAt: window.resetsAt)])
        #expect(QuotaForecast.current(window: window, provider: "claude", history: sparse, stale: false, now: updatedAt)
                == window.forecast)
        var plain = window
        plain.forecast = nil
        #expect(QuotaForecast.current(window: plain, provider: "claude", history: sparse, stale: false, now: updatedAt) == nil)
    }

    // MARK: - 整合審查 D-i：只有 Codex（plan null、超過 100%）、沒有任何服務

    @Test func codexOnlyOverHundredPercent() throws {
        let codexOnly = try Self.load("usage-codex-only.json")
        #expect(codexOnly.orderedProviderKeys == ["codex"])
        #expect(!codexOnly.hasNoProviders)
        let codex = try #require(codexOnly.providers["codex"])
        #expect(codex.plan == nil)
        #expect(codex.error == nil)
        #expect(codex.windows[0].usedPct == 112.5)
        // 超過 100% 以剩 0% 顯示，且是剩餘最少的額度
        let tightest = try #require(codexOnly.tightestWindow(at: updatedAt))
        #expect(tightest.provider == "codex")
        #expect(tightest.window.id == "five_hour")
        #expect(tightest.window.effectiveRemainingPct(at: updatedAt) == 0)
        let state = UsageActivityState(snapshot: codexOnly, mode: .remaining)
        #expect(!state.hasPartialFailure)
        // 重置卷 3 張，明細 2 張（一張 10/23 03:00Z 到期、一張不會到期）
        let credits = try #require(codex.resetCredits)
        #expect(credits.available == 3)
        #expect(credits.credits.map(\.expiresAt) == [Date(timeIntervalSince1970: 1_792_724_400), nil])
        #expect(try UsageDecoder.decode(UsageEncoder.encode(codexOnly)) == codexOnly)
    }

    @Test func noProvidersIsNotAnError() throws {
        let empty = try Self.load("usage-no-providers.json")
        #expect(empty.hasNoProviders)
        #expect(empty.orderedProviderKeys.isEmpty)
        #expect(empty.tightestWindow(at: updatedAt) == nil)
        let state = UsageActivityState(snapshot: empty, mode: .remaining)
        #expect(!state.hasPartialFailure)
        #expect(state.providers.isEmpty)
        #expect(try UsageDecoder.decode(UsageEncoder.encode(empty)) == empty)
    }
}
