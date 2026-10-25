import Foundation
import Testing
@testable import UsageKit

/// usage.json 的本機狀態（ADR-0014 LT-06）：只在 Mac 本機的檔案裡；沒有時（中繼的快照、舊版收集器）為 nil
struct LocalStatusTests {
    private func decode(_ extra: String) throws -> UsageSnapshot {
        let json = """
        {"schema_version": 1, "updated_at": "2026-10-26T01:00:00Z", "providers": {}\(extra)}
        """
        return try UsageDecoder.decode(Data(json.utf8))
    }

    @Test func lowDiskIsDecoded() throws {
        let s = try decode(#", "local_status": {"history_paused": "low_disk", "disk_free_mb": 312}"#)
        #expect(s.localStatus == LocalStatus(historyPaused: "low_disk", diskFreeMB: 312))
        #expect(s.localStatus?.lowDisk == true)
    }

    @Test func missingStatusIsNil() throws {
        #expect(try decode("").localStatus == nil)
    }

    @Test func unknownReasonIsNotLowDisk() throws {
        let s = try decode(#", "local_status": {"history_paused": "something_new"}"#)
        #expect(s.localStatus?.lowDisk == false)
    }

    @Test func encodingWithoutStatusOmitsTheKey() throws {
        let s = UsageSnapshot(updatedAt: Date(timeIntervalSince1970: 0), providers: [:])
        let data = try JSONEncoder().encode(s)
        #expect(String(decoding: data, as: UTF8.self).contains("local_status") == false)
    }
}
