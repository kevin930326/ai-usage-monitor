import Testing
@testable import UsageKit

@Suite struct AppearanceChoiceTests {
    @Test func defaultsToSystem() {
        #expect(AppearanceChoice(stored: nil) == .system)
        #expect(AppearanceChoice(stored: "") == .system)
        #expect(AppearanceChoice(stored: "sepia") == .system)
    }

    @Test func roundTripsStoredValues() {
        for choice in AppearanceChoice.allCases {
            #expect(AppearanceChoice(stored: choice.rawValue) == choice)
        }
    }

    @Test func titlesInOrder() {
        #expect(AppearanceChoice.allCases.map(\.title) == ["跟隨系統", "淺色", "深色"])
    }
}
