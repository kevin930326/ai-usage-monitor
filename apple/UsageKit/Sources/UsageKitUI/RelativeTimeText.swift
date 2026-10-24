import SwiftUI
import UsageKit

public extension Text {
    /// 會自動更新的相對時間（`Text(date, style: .relative)`）。系統的相對時間一律以真的現在計算，
    /// 截圖比對固定時間（`RenderClock.fixed`）時改用以固定時間算出、不會更新的文字，每次畫出來都一樣。
    static func relative(to date: Date) -> Text {
        guard let now = RenderClock.fixed else { return Text(date, style: .relative) }
        return Text(verbatim: ResetCountdown.text(until: max(date, now), now: min(date, now)) ?? "0分鐘")
    }
}
