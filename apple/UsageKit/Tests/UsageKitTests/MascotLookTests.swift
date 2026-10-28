import Foundation
import Testing
@testable import UsageKit

/// `shared/mascot-looks.json`（ADR-0021）：清單照使用者挑的、每個外觀的顏色齊全
@Suite struct MascotLookTests {
    static let url = MascotGoldenTests.repo.appendingPathComponent("shared/mascot-looks.json")

    @Test func sharedFileHasThePickedLooks() throws {
        let file = try MascotLooks.decode(Data(contentsOf: Self.url))
        #expect(file.looks.map(\.id) == ["D3", "T5", "C1", "C3", "C4", "M1", "M2", "X9", "X10", "X8", "X4", "X3"])
        // 深色身體眼睛用亮色；可愛風有腮紅
        #expect(file.look("T5")?.eye == [0xEA, 0xF0, 0xFF])
        #expect(file.look("M1")?.eye == [0xF2, 0xF2, 0xF2])
        #expect(file.looks.filter(\.blush).map(\.id) == ["C1", "C3", "C4"])
        #expect(file.look("X10")?.style.animates == false)
        #expect(file.look("X3")?.style == .ascii)
        #expect(file.look(nil) == nil)
        #expect(file.look("D1") == nil)
    }

    @Test func rejectsIncompleteLooks() throws {
        let missing = ##"{"version":1,"groups":[{"id":"g","name":"g"}],"looks":[{"id":"A","name":"a","group":"g","style":"solid","glow":"#FFFFFF"}]}"##
        #expect(throws: DecodingError.self) { try MascotLooks.decode(Data(missing.utf8)) }
        let duplicate = ##"{"version":1,"groups":[{"id":"g","name":"g"}],"looks":[{"id":"A","name":"a","group":"g","style":"neon","color":"#FFFFFF","glow":"#FFFFFF"},{"id":"A","name":"a","group":"g","style":"neon","color":"#FFFFFF","glow":"#FFFFFF"}]}"##
        #expect(throws: DecodingError.self) { try MascotLooks.decode(Data(duplicate.utf8)) }
        #expect(throws: DecodingError.self) { try MascotLook.rgb("#12345") }
        #expect(try MascotLook.rgb("#EC9674") == [236, 150, 116])
    }
}
