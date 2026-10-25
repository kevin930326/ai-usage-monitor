import Foundation
import Testing
@testable import UsageKit

/// 重置次數卷（FR-58、FR-59）：選填欄位的解碼、面板與 iPhone 的一行、滑鼠說明與到期通知。
@Suite struct ResetCreditsTests {
    let now = Date(timeIntervalSince1970: 1_792_555_200) // 2026-10-21T04:00:00Z（台北 12:00）
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86400) }

    func credits(_ available: Int, _ expiries: [Date?]) -> ResetCredits {
        ResetCredits(available: available, credits: expiries.map { .init(expiresAt: $0) })
    }

    // MARK: - 解碼

    func decode(_ provider: String) throws -> ProviderUsage? {
        let json = #"{"schema_version":1,"updated_at":"2026-10-21T04:00:00Z","providers":{"codex":\#(provider)}}"#
        return try UsageDecoder.decode(Data(json.utf8)).providers["codex"]
    }

    @Test func oldSnapshotWithoutFieldDecodes() throws {
        let codex = try #require(try decode(#"{"plan":"Team","error":null,"windows":[]}"#))
        #expect(codex.resetCredits == nil)
    }

    @Test func decodesCountAndExpiries() throws {
        let codex = try decode(#"""
            {"plan":"Team","error":null,"windows":[],
             "reset_credits":{"available":2,"credits":[{"expires_at":"2026-10-23T04:00:00Z"},{"expires_at":null}]}}
            """#)
        #expect(codex?.resetCredits == credits(2, [days(2), nil]))
        // 沒有明細
        #expect(try decode(#"{"windows":[],"reset_credits":{"available":1}}"#)?.resetCredits == credits(1, []))
    }

    @Test func malformedFieldDoesNotBreakSnapshot() throws {
        for bad in [#""2""#, #"{"available":"2"}"#, #"{"available":1,"credits":[{"expires_at":"soon"}]}"#] {
            let codex = try #require(try decode(#"{"plan":"Team","windows":[],"reset_credits":\#(bad)}"#))
            #expect(codex.plan == "Team")
            #expect(codex.resetCredits == nil)
        }
    }

    @Test func encoderOmitsMissingFieldAndRoundTrips() throws {
        let plain = UsageSnapshot(updatedAt: now, providers: ["codex": ProviderUsage(plan: "Team")])
        #expect(!String(decoding: try UsageEncoder.encode(plain), as: UTF8.self).contains("reset_credits"))
        let withCredits = UsageSnapshot(updatedAt: now, providers: [
            "codex": ProviderUsage(plan: "Team", resetCredits: credits(2, [days(2), nil])),
        ])
        #expect(try UsageDecoder.decode(UsageEncoder.encode(withCredits)) == withCredits)
    }

    // MARK: - 顯示

    @Test func summaryLine() {
        #expect(credits(2, [days(30), days(2)]).summary(at: now, calendar: calendar) == "重置卷 2 張 · 最早 10/23 到期")
        #expect(credits(1, [days(2)]).summary(at: now, calendar: calendar) == "重置卷 1 張 · 10/23 到期")
        #expect(credits(2, [nil]).summary(at: now, calendar: calendar) == "重置卷 2 張")
        #expect(credits(3, []).summary(at: now, calendar: calendar) == "重置卷 3 張")
        // 0 張不顯示
        #expect(credits(0, []).summary(at: now, calendar: calendar) == nil)
        #expect(credits(2, [days(2)]).accessibilityLabel(at: now, calendar: calendar) == "重置卷 2 張，最早 10 月 23 日到期")
    }

    @Test func expiredCreditsAreNotCounted() {
        // Mac 離線時資料停在到期前：已過到期時間的卷不算
        let c = credits(2, [days(-1), days(2)])
        #expect(c.usableCount(at: now) == 1)
        #expect(c.summary(at: now, calendar: calendar) == "重置卷 1 張 · 10/23 到期")
        #expect(credits(1, [days(-1)]).summary(at: now, calendar: calendar) == nil)
    }

    @Test func creditsExpiringTogetherAreOneGroup() throws {
        // 審查 C-02：17 張同時到期是一組，到期後全部扣掉、不再顯示
        let c = ResetCredits(available: 19, credits: [.init(expiresAt: days(1), count: 17), .init(expiresAt: nil, count: 2)])
        #expect(c.summary(at: now, calendar: calendar) == "重置卷 19 張 · 最早 10/22 到期")
        #expect(c.detailLines(at: now, calendar: calendar) == ["10/22 12:00 到期（17 張）", "不會到期（2 張）"])
        #expect(c.expiring(at: now).map(\.count) == [17])
        #expect(c.usableCount(at: days(2)) == 2)
        #expect(credits(17, [days(1)]).usableCount(at: days(2)) == 16)  // 舊格式（沒有 count）一筆算 1 張
        #expect(ResetCredits(available: 17, credits: [.init(expiresAt: days(1), count: 17)]).summary(at: days(2), calendar: calendar) == nil)
        // 解碼：count 沒給時是 1
        let codex = try decode(#"{"windows":[],"reset_credits":{"available":3,"credits":[{"expires_at":null,"count":2},{"expires_at":null}]}}"#)
        #expect(codex?.resetCredits?.credits.map(\.count) == [2, 1])
    }

    @Test func detailLinesListEachCredit() {
        let c = credits(4, [nil, days(2), days(30)])
        #expect(c.detailLines(at: now, calendar: calendar) == ["10/23 12:00 到期", "11/20 12:00 到期", "不會到期", "另 1 張到期日不明"])
        #expect(credits(2, []).detailLines(at: now, calendar: calendar) == ["到期日不明"])
    }

    // MARK: - 通知（3 天內到期，同一張只通知一次）

    func snapshot(_ c: ResetCredits?, updatedAgo: TimeInterval = 60, error: String? = nil) -> UsageSnapshot {
        UsageSnapshot(updatedAt: now.addingTimeInterval(-updatedAgo), providers: [
            "codex": ProviderUsage(plan: "Team", error: error, windows: [
                UsageWindow(id: "weekly", label: "每週", usedPct: 10, resetsAt: days(5)),
            ], resetCredits: c),
        ])
    }

    @Test func expiringWithinThreeDaysNotifiesOncePerCredit() {
        let s = snapshot(credits(3, [days(2), days(2.5), days(30)]))
        let alerts = QuotaAlerts.detect(snapshot: s, now: now, sent: [])
        #expect(alerts.map(\.kind) == [.creditExpiring, .creditExpiring])
        #expect(alerts[0].title == "Codex 重置卷快到期")
        #expect(alerts[0].body.hasPrefix("1 張重置卷約 2天後到期（"))
        #expect(alerts[0].cardID == "quota")
        #expect(alerts[0].key == "creditExpiring|codex|reset_credits|\(Int64(days(2).timeIntervalSince1970))")
        // 送過就不再送；30 天後到期的那張到了 3 天內才送
        let sent = Set(alerts.map(\.key))
        #expect(QuotaAlerts.detect(snapshot: s, now: now.addingTimeInterval(600), sent: sent).isEmpty)
        let later = QuotaAlerts.detect(snapshot: UsageSnapshot(updatedAt: days(27.5), providers: s.providers), now: days(27.5), sent: sent)
        #expect(later.map(\.key) == ["creditExpiring|codex|reset_credits|\(Int64(days(30).timeIntervalSince1970))"])
        // 到期時間還在未來：鍵不會在到期前被清掉
        #expect(QuotaAlerts.pruned(sent, now: days(1)) == sent)
    }

    @Test func creditsExpiringAtTheSameTimeAreOneAlert() {
        let alerts = QuotaAlerts.detect(snapshot: snapshot(credits(2, [days(1), days(1)])), now: now, sent: [])
        #expect(alerts.count == 1)
        #expect(alerts.first?.body.hasPrefix("2 張重置卷") == true)
    }

    @Test func noAlertWhenNothingExpiresSoon() {
        for c in [nil, credits(0, []), credits(2, [nil, days(4)]), credits(1, [days(-0.1)])] {
            #expect(QuotaAlerts.detect(snapshot: snapshot(c), now: now, sent: []).isEmpty)
        }
        // 資料過期或服務失敗時不判斷
        #expect(QuotaAlerts.detect(snapshot: snapshot(credits(1, [days(1)]), updatedAgo: 3600), now: now, sent: []).isEmpty)
        #expect(QuotaAlerts.detect(snapshot: snapshot(credits(1, [days(1)]), error: "x"), now: now, sent: []).isEmpty)
    }
}
