import Foundation
import Testing
@testable import UsageKit

/// 顏色規則與 WCAG 對比度（FR-16）：文字 ≥ 4.5:1、進度條等圖形 ≥ 3:1。
@Suite struct UsagePaletteTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers = ["claude", "codex", "gemini"]

    @Test func contrastRatioMatchesWCAGReferences() {
        #expect(abs(RGBColor(0x000000).contrastRatio(with: RGBColor(0xFFFFFF)) - 21) < 0.01)
        #expect(RGBColor(0x777777).contrastRatio(with: RGBColor(0xFFFFFF)) > 4.47)
        #expect(RGBColor(0x777777).contrastRatio(with: RGBColor(0xFFFFFF)) < 4.49)
    }

    @Test func darkProviderColorsAreTheBrandColors() {
        #expect(UsagePalette.provider("claude").dark == RGBColor(0xD97757))
        #expect(UsagePalette.provider("codex").dark == RGBColor(0x5CC2B1))
        #expect(UsagePalette.provider("claude") != UsagePalette.provider("codex"))
    }

    /// 動態島與圓形複雜功能的服務圖示是黑底上的識別色（圖示很小，沿用文字的 4.5:1 標準）
    @Test func providerMarksAreReadableOnBlack() {
        for key in providers {
            #expect(UsagePalette.provider(key).dark.contrastRatio(with: UsagePalette.blackBackground) >= 4.5, "\(key)")
        }
    }

    /// 進度條：淺色外觀對白色、深色外觀對深灰，都要 ≥ 3:1（WCAG 非文字對比）
    @Test(arguments: ["claude", "codex", "gemini"])
    func barsAreVisibleInBothAppearances(key: String) {
        let color = UsagePalette.provider(key)
        #expect(color.light.contrastRatio(with: UsagePalette.lightBackground) >= 3)
        #expect(color.dark.contrastRatio(with: UsagePalette.darkBackground) >= 3)
    }

    @Test func criticalBarIsVisibleInBothAppearances() {
        #expect(UsagePalette.critical.light.contrastRatio(with: UsagePalette.lightBackground) >= 3)
        #expect(UsagePalette.critical.dark.contrastRatio(with: UsagePalette.darkBackground) >= 3)
    }

    /// 「資料已過期」等提示文字（取代各畫面寫死的 .orange；系統橘色在白底只有 2.2:1）
    @Test func noticeTextMeetsAA() {
        #expect(UsagePalette.notice.light.contrastRatio(with: UsagePalette.lightBackground) >= 4.5)
        #expect(UsagePalette.notice.dark.contrastRatio(with: UsagePalette.darkBackground) >= 4.5)
        #expect(UsagePalette.notice.dark.contrastRatio(with: UsagePalette.blackBackground) >= 4.5)
    }

    // MARK: 進度條顏色規則

    func window(remaining: Double, resetsIn: TimeInterval? = 3600) -> UsageWindow {
        UsageWindow(id: "five_hour", label: "5 小時", usedPct: 100 - remaining, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    @Test func barUsesProviderColorDownToTwentyPercent() {
        #expect(window(remaining: 80).barTone(stale: false, at: now) == .provider)
        // 20–50% 不再另外上色
        #expect(window(remaining: 35).barTone(stale: false, at: now) == .provider)
        #expect(window(remaining: 20).barTone(stale: false, at: now) == .provider)
    }

    @Test func barTurnsRedBelowTwentyPercent() {
        #expect(window(remaining: 19.9).barTone(stale: false, at: now) == .critical)
        #expect(window(remaining: 0).barTone(stale: false, at: now) == .critical)
    }

    @Test func staleDataIsGrayEvenWhenCritical() {
        #expect(window(remaining: 5).barTone(stale: true, at: now) == .stale)
    }

    @Test func resetWindowIsNoLongerCritical() {
        #expect(window(remaining: 5, resetsIn: -60).barTone(stale: false, at: now) == .provider)
    }
}
