import Foundation
import Testing
@testable import UsageKit

/// 第二層的裝置範圍（ADR-0011 第 4 節）
@Suite struct TokenDevicesTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    /// 2026-11-05（星期四）15:00 台北
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15))! }

    let pcID = "0f8e2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b"
    let laptopID = "1a2b3c4d-1b2d-4e5f-8a9b-0c1d2e3f4a5b"

    func row(_ day: String, _ input: Int64, device: String = TokenDevices.local, longest: Int = 0) -> TokenDayRow {
        TokenDayRow(day: day, provider: "claude", model: "claude-opus-5-5", counts: TokenCounts(input: input),
                    taskSeconds: longest, longestTaskSeconds: longest, device: device)
    }

    var devices: TokenDevices {
        TokenDevices(devices: [
            TokenDevice(id: "self-id", name: "Mac", lastUpload: now.addingTimeInterval(-1800), isSelf: true),
            TokenDevice(id: pcID, name: "工作 PC", lastUpload: now.addingTimeInterval(-2 * 3600)),
            TokenDevice(id: laptopID, name: "筆電", lastUpload: now.addingTimeInterval(-3 * 86400 - 60)),
        ])
    }

    var data: TokenStatsData {
        TokenStatsData(days: [row("2026-11-05", 100, longest: 50), row("2026-11-05", 40, device: pcID, longest: 900),
                              row("2026-11-04", 7, device: laptopID)],
                       hours: [TokenHourRow(day: "2026-11-05", hour: 14, provider: "claude", model: "claude-opus-5-5", counts: TokenCounts(input: 100))],
                       records: ["total_tokens": TokenRecord(value: 5000), "longest_task_seconds": TokenRecord(value: 60, day: "2026-10-01")],
                       recordDays: ["2026-11-05": ["claude": 100]], firstScanDone: true, devices: devices)
    }

    @Test func withoutOtherDevicesItStaysThisMac() {
        let only = TokenDevices(devices: [TokenDevice(id: "self-id", name: "Mac", isSelf: true)])
        for d in [TokenDevices.none, only] {
            #expect(!d.enabled)
            #expect(d.scopes == [.thisMac])
            #expect(d.resolve(.all) == .thisMac)
            #expect(d.resolve(nil) == .thisMac)
        }
    }

    @Test func scopesAndTitles() {
        let d = devices
        #expect(d.enabled)
        #expect(d.scopes == [.all, .thisMac, .device(pcID), .device(laptopID)])
        #expect(d.title(.all) == "所有電腦（3 台）")
        #expect(d.title(.thisMac) == "這台 Mac")
        #expect(d.title(.device(pcID)) == "工作 PC")
        #expect(d.resolve(nil) == .all)
        #expect(d.resolve(.device("deleted")) == .all)
        #expect(d.resolve(.device(pcID)) == .device(pcID))
    }

    @Test func staleDevicesAreMarkedInTheMenu() {
        let d = devices
        #expect(d.menuTitle(.device(pcID), now: now) == "工作 PC")
        #expect(d.menuTitle(.device(laptopID), now: now) == "筆電（3 天前更新）")
        #expect(TokenDevices.staleNote(TokenDevice(id: "x", name: "x"), now: now) == "尚未上傳")
        // 撤銷了密鑰但保留資料的電腦：分得出「沒在用」與「已撤銷」，仍算在「N 台」裡
        var revoked = d
        revoked.devices[1].revoked = true
        #expect(revoked.menuTitle(.device(pcID), now: now) == "工作 PC（已撤銷）")
        #expect(revoked.title(.all) == "所有電腦（3 台）")
    }

    @Test func helpListsEveryComputerWithItsLastUpload() {
        let help = devices.help(.all, now: now)
        #expect(help.contains("這台 Mac（剛剛上傳）、工作 PC（2 小時前上傳）、筆電（3 天前上傳）"))
        #expect(help.contains("不包含 claude.ai 網頁、手機 App 與雲端 session"))
        #expect(devices.help(.thisMac, now: now) == TokenDevices.thisMacHelp)
        #expect(devices.help(.device(pcID), now: now).contains("「工作 PC」"))
    }

    @Test func thisMacKeepsLocalRowsAndRecords() {
        let local = data.scoped(.thisMac)
        #expect(local.days.map(\.counts.input) == [100])
        #expect(local.records["total_tokens"]?.value == 5000)
        #expect(local.hours.count == 1)
    }

    @Test func allSumsEveryDeviceAndComputesRecordsFromDays() {
        let all = data.scoped(.all)
        let summary = TokenSummary(data: all, scope: .all, now: now, calendar: cal)
        #expect(summary.thisWeek.main == 147)
        #expect(summary.longestTaskSeconds?.value == 900)  // PC 的任務：不是本機 records 的 60
        #expect(summary.total?.value == 147)
        #expect(all.hours.count == 1)  // 每小時資料只有這台 Mac 的
    }

    @Test func oneOtherDeviceHasOnlyItsRows() {
        let pc = data.scoped(.device(pcID))
        #expect(pc.days.map(\.counts.input) == [40])
        #expect(pc.records.isEmpty && pc.recordDays.isEmpty && pc.hours.isEmpty)
        #expect(pc.firstScanDone)
        #expect(TokenSummary(data: pc, scope: .all, now: now, calendar: cal).thisWeek.main == 40)
    }

    @Test func scopeRawValueRoundTrips() {
        for scope in [TokenDeviceScope.thisMac, .all, .device(pcID)] {
            #expect(TokenDeviceScope(rawValue: scope.rawValue) == scope)
        }
        #expect(TokenDeviceScope(rawValue: "device:") == nil)
        #expect(TokenDeviceScope(rawValue: "x") == nil)
    }

    @Test func emptyTexts() {
        #expect(TokenStatsData.emptyText(.device(pcID), devices: devices) == "「工作 PC」還沒有上傳 Token 統計")
        #expect(TokenStatsData.emptyText(.thisMac, devices: devices).hasPrefix("這台 Mac"))
    }
}
