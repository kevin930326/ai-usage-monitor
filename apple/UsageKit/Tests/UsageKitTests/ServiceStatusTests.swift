import Foundation
import Testing
@testable import UsageKit

@Suite struct ServiceStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func file(_ providers: String, updatedAgo: TimeInterval = 60) -> Data {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-updatedAgo))
        return Data(#"{"schema_version": 1, "updated_at": "\#(stamp)", "providers": {\#(providers)}}"#.utf8)
    }

    let disrupted = #""claude": {"indicator": "major", "description": "Partial outage", "components": [{"name": "Claude Code", "status": "partial_outage", "related": true}], "incidents": [{"name": "Elevated errors", "impact": "major"}], "page": "https://status.claude.com", "error": null}"#
    let healthy = #""codex": {"indicator": "none", "description": "All Systems Operational", "components": [], "incidents": [], "page": "https://status.openai.com", "error": null}"#

    @Test func decodesAndSummarizes() throws {
        let status = try #require(ServiceStatusFile.decode(file(disrupted + ", " + healthy)))
        #expect(status.providers["claude"]?.affectsTool == true)
        #expect(ServiceStatusSummary.health(status, provider: "claude", now: now)
            == .disrupted(summary: "Elevated errors", affectsTool: true))
        #expect(ServiceStatusSummary.health(status, provider: "codex", now: now) == .operational)
        #expect(ServiceStatusSummary.health(status, provider: "gemini", now: now) == .unknown)
    }

    @Test func staleErrorOrBrokenIsUnknown() {
        let stale = ServiceStatusFile.decode(file(disrupted, updatedAgo: 3600))
        #expect(ServiceStatusSummary.health(stale, provider: "claude", now: now) == .unknown)
        let failed = ServiceStatusFile.decode(file(#""claude": {"indicator": null, "components": [], "incidents": [], "error": "網路錯誤"}"#))
        #expect(ServiceStatusSummary.health(failed, provider: "claude", now: now) == .unknown)
        #expect(ServiceStatusFile.decode(Data("not json".utf8)) == nil)
        #expect(ServiceStatusSummary.health(nil, provider: "claude", now: now) == .unknown)
    }

    @Test func maintenanceIsSeparate() {
        let status = ServiceStatusFile.decode(file(#""claude": {"indicator": "maintenance", "description": "Scheduled", "components": [], "incidents": [], "error": null}"#))
        #expect(ServiceStatusSummary.health(status, provider: "claude", now: now) == .maintenance(summary: "Scheduled"))
    }

    @Test func quotaVersusOutage() {
        let exhausted = UsageSnapshot(updatedAt: now, providers: [
            "claude": ProviderUsage(plan: "Max", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 100, resetsAt: now.addingTimeInterval(3600)),
            ]),
        ])
        #expect(ServiceStatusSummary.quotaExhausted(exhausted, provider: "claude", now: now))
        // 重置時間已過：不算用完
        #expect(!ServiceStatusSummary.quotaExhausted(exhausted, provider: "claude", now: now.addingTimeInterval(7200)))
        let outage = ServiceHealth.disrupted(summary: "x", affectsTool: true)
        #expect(ServiceStatusSummary.explanation(health: outage, quotaExhausted: false, provider: "claude")
            == "Claude 服務異常，不是額度用完；稍後再試")
        #expect(ServiceStatusSummary.explanation(health: .operational, quotaExhausted: true, provider: "claude")
            == "Claude 的額度已用完（服務正常），等重置")
        #expect(ServiceStatusSummary.explanation(health: outage, quotaExhausted: true, provider: "claude")
            == "Claude 的額度已用完，同時服務也有異常")
        #expect(ServiceStatusSummary.explanation(health: .unknown, quotaExhausted: false, provider: "claude") == nil)
    }
}
