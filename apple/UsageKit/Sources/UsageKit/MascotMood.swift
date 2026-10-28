import Foundation

/// 角色平常（沒有在播動畫、眼睛是膠囊時）顯示的表情。額度與狀態改用眼睛和眉毛表示，沒有狀態點
/// （ADR-0016 第 1 節；ADR-0008「不能只靠顏色」：每種表情的眼睛形狀都不同，灰階也分得出來）。
/// 選單列的角色圖示用同一套眼睛（正常膠囊、偏高小圓點、用完 ×、過期閉眼）。
public enum MascotMood: String, Sendable, CaseIterable {
    /// 正常：膠囊眼
    case normal
    /// 額度偏高（剩不到 20%）：小圓點眼＋擔心的眉毛
    case worried
    /// 額度用完：× 眼
    case out
    /// 資料過期或讀取失敗：閉眼
    case stale
    /// 開心：^ ^（右鍵選單的表情）
    case happy
    /// 難過：眼睛下半閉、眉毛往下垂
    case sad
    /// 生病：半閉的眼、擔心的眉毛、冒冷汗
    case sick
    /// 驚訝：圓點眼、眉毛抬高
    case surprised

    public var title: String {
        switch self {
        case .normal: "平常"
        case .worried: "擔心"
        case .out: "用完"
        case .stale: "閉眼"
        case .happy: "開心"
        case .sad: "難過"
        case .sick: "生病"
        case .surprised: "驚訝"
        }
    }

    /// 眉毛的樣子
    public enum Brow: Sendable, Equatable {
        case none
        /// 內側抬高（擔心）
        case worried
        /// 內側抬高、更斜（難過）
        case sad
        /// 整條抬高（驚訝）
        case raised
    }

    /// 取代膠囊眼的樣子；nil 表示維持膠囊（可以眨眼）
    public var eyes: MascotEyes? {
        switch self {
        case .normal, .sad, .sick: nil
        case .worried, .surprised: .dot
        case .out: .cross
        case .happy: .happy
        case .stale: nil
        }
    }

    /// 眼皮蓋住多少（0 張開 … 1 閉成一條線）
    public var lid: Double {
        switch self {
        case .stale: 1
        case .sick: 0.55
        case .sad: 0.45
        default: 0
        }
    }

    public var brow: Brow {
        switch self {
        case .worried, .sick: .worried
        case .sad: .sad
        case .surprised: .raised
        default: .none
        }
    }

    /// 冒冷汗（生病）
    public var sweat: Bool { self == .sick }

    /// 額度的表情：狀態等級（0 正常、1 偏高、2 用完）＋資料是否過期或讀取失敗
    public static func quota(level: Int, unavailable: Bool) -> MascotMood {
        if unavailable { return .stale }
        return level >= 2 ? .out : level == 1 ? .worried : .normal
    }

    /// 額度不明（閉眼）：還沒有資料、讀檔失敗（包括有舊資料時）、資料過期、選的服務沒有資料或出錯、
    /// 或沒有任何看得到的額度（Codex C-04、第二輪 C-01）
    public static func isQuotaUnavailable(_ snapshot: UsageSnapshot?, provider: String, readFailed: Bool, now: Date) -> Bool {
        guard let snapshot, !readFailed, !snapshot.isStale(now: now),
              let usage = snapshot.providers[provider], usage.error == nil else { return true }
        return usage.visibleWindows.isEmpty
    }
}

/// 靜音與勿擾（右鍵選單）：角色的提醒動畫與瀏海的通知暫停到某個時間
public enum MascotQuiet {
    /// 「勿擾到明天」：明天早上 8 點（本機時區）
    public static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

extension MascotMood {
    /// 選單「表情」的動畫播的是哪個表情（沒有對應的回傳 nil）
    public static func face(of animation: MascotAnimation) -> MascotMood? {
        switch animation {
        case .faceHappy: .happy
        case .faceWorried: .worried
        case .faceSad: .sad
        case .faceSick: .sick
        case .faceSurprised: .surprised
        case .faceOut: .out
        case .faceStale: .stale
        default: nil
        }
    }

    /// 選單要求這個表情時送的要求（平常的表情沒有）
    public var faceRequest: MascotRequest? {
        switch self {
        case .happy: .faceHappy
        case .worried: .faceWorried
        case .sad: .faceSad
        case .sick: .faceSick
        case .surprised: .faceSurprised
        case .out: .faceOut
        case .stale: .faceStale
        case .normal: nil
        }
    }
}
