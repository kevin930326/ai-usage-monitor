import Foundation

/// 收合時 AI 工作中的思考泡泡（ADR-0021 第 4 節，2026-10-29）：角色右上方三個小點依序亮起，三顆全亮後清空重來。
/// Mac 把它畫進 Core Animation 循環播放的那一輪，所以每一步要能整除一輪的長度，接回開頭才看不出斷點。
public enum MascotThinking {
    /// 每多亮一顆的目標間隔（參考頁 260 毫秒）
    public static let targetStepMs = 260.0
    /// 背景執行中（ADR-0017 第 7 節）：一半的速度
    public static let slowStepMs = 520.0

    /// 一輪 `loop` 毫秒裡每一步的長度：一輪走整數次「0 → 1 → 2 → 3 顆」，最接近目標間隔
    public static func stepMs(loop: Double, target: Double = targetStepMs) -> Double {
        loop / (max(1, (loop / (target * 4)).rounded()) * 4)
    }

    /// 第 `t` 毫秒亮了幾顆（0…3）
    public static func dots(at t: Int, loop: Double, target: Double = targetStepMs) -> Int {
        Int((Double(t).truncatingRemainder(dividingBy: loop) / stepMs(loop: loop, target: target)).rounded(.down)) % 4
    }
}
