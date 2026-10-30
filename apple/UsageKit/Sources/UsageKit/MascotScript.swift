import Foundation

// 角色的姿勢（ADR-0016 第 1 節）：畫面是「狀態＋時間＋種子」的純函式。demo 用 `to(屬性, 長度, 緩動)` 從目前的值
// 補間；這裡把每一段（過場、展開、收合、每個動畫、回位、模式姿勢）寫成一份腳本：起始姿勢＋依時間排列的補間，
// 任一時間點的姿勢都可以直接算出來，不保存「進行到哪」。換下一段時，以上一段在那一刻的姿勢當新腳本的起點。

/// 姿勢的每個參數（名稱同 notch-demo.html 的 hero）
public enum MascotProp: Int, CaseIterable, Sendable {
    case x, y, r, sc, yaw, pitch, roll, open, dash, hands, wave, sway, tint, dot, glow, follow
    case sx, sy, jump, orbit, shiver, blush, type, kb, breathe
    case lx, ly, lz, rx, ry, rz
}

public struct MascotPose: Sendable, Equatable {
    public var values: [Double]

    public init(_ pairs: [MascotProp: Double] = [:]) {
        values = Array(repeating: 0, count: MascotProp.allCases.count)
        for (prop, value) in pairs { values[prop.rawValue] = value }
    }

    public subscript(_ prop: MascotProp) -> Double {
        get { values[prop.rawValue] }
        set { values[prop.rawValue] = newValue }
    }

    public func with(_ pairs: [MascotProp: Double]) -> MascotPose {
        var copy = self
        for (prop, value) in pairs { copy[prop] = value }
        return copy
    }
}

/// 緩動曲線（同 demo 的 EO、EIO、EIN、EXP、BACK、BACKS）
public enum MascotEase: String, Sendable, Codable {
    case linear, out, inOut, inCubic, expoOut, back, backSoft

    public func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .out: return 1 - pow(1 - t, 3)
        case .inOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .inCubic: return t * t * t
        case .expoOut: return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case .back: return Self.back(t, 1.7)
        case .backSoft: return Self.back(t, 1.0)
        }
    }

    private static func back(_ t: Double, _ c: Double) -> Double {
        1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
}

/// 眼睛樣式（閉眼「– –」以 `dash` 參數表示，不是另一種樣式）
public enum MascotEyes: String, Sendable {
    case pill, happy, dot, xx, spiral
    /// ×（額度用完）
    case cross
}

/// 角色身邊的小特效
public enum MascotEffectKind: Sendable, Equatable {
    case heart
    case bang
    /// 額度提醒推出的光環（0 正常、1 偏高、2 用完）
    case ring(level: Int)
}

public struct MascotEffect: Sendable, Equatable {
    public var kind: MascotEffectKind
    /// 絕對時間（ms）
    public var start: Int
    public var duration: Int

    public init(kind: MascotEffectKind, start: Int, duration: Int) {
        self.kind = kind
        self.start = start
        self.duration = duration
    }

    public func progress(at time: Int) -> Double? {
        guard time >= start, time < start + duration else { return nil }
        return Double(time - start) / Double(duration)
    }
}

/// 一段腳本：起點（絕對時間）、起始姿勢與眼睛、之後的補間、換眼睛的時間點與特效
public struct MascotScript: Sendable {
    public struct Tween: Sendable {
        public var at: Int
        public var prop: MascotProp
        public var to: Double
        public var duration: Int
        public var ease: MascotEase
    }

    public var start: Int
    public var base: MascotPose
    public var baseEyes: MascotEyes
    public private(set) var tweens: [Tween] = []
    public private(set) var eyes: [(at: Int, eyes: MascotEyes)] = []
    public private(set) var effects: [MascotEffect] = []

    public init(start: Int, base: MascotPose, eyes: MascotEyes = .pill) {
        self.start = start
        self.base = base
        baseEyes = eyes
    }

    /// 和 demo 的 `to({...}, dur, ease)` 一樣：`at` 是從這段開始算的毫秒；同一個參數後來的補間取代先前的
    public mutating func to(_ pairs: [MascotProp: Double], _ duration: Int, _ ease: MascotEase = .out, at: Int = 0) {
        for prop in MascotProp.allCases {
            guard let value = pairs[prop] else { continue }
            tweens.append(Tween(at: at, prop: prop, to: value, duration: max(duration, 1), ease: ease))
        }
    }

    public mutating func setEyes(_ style: MascotEyes, at: Int = 0) {
        if at <= 0, eyes.isEmpty {
            baseEyes = style
        } else {
            eyes.append((at, style))
        }
    }

    public mutating func effect(_ kind: MascotEffectKind, duration: Int, at: Int = 0) {
        effects.append(MascotEffect(kind: kind, start: start + at, duration: duration))
    }

    /// 某個參數在 `time`（絕對時間）的值：依時間順序走過這個參數的補間，每一段從前一段在它開始時的值出發
    public func value(_ prop: MascotProp, at time: Int) -> Double {
        let local = time - start
        var active: (tween: Tween, from: Double)?
        for tween in tweens where tween.prop == prop {
            guard tween.at <= local else { break }
            let from = active.map { Self.evaluate($0.tween, from: $0.from, at: tween.at) } ?? base[prop]
            active = (tween, from)
        }
        guard let active else { return base[prop] }
        return Self.evaluate(active.tween, from: active.from, at: local)
    }

    private static func evaluate(_ tween: Tween, from: Double, at local: Int) -> Double {
        let u = Double(local - tween.at) / Double(tween.duration)
        return from + (tween.to - from) * tween.ease(u)
    }

    public func pose(at time: Int) -> MascotPose {
        var pose = MascotPose()
        for prop in MascotProp.allCases { pose[prop] = value(prop, at: time) }
        return pose
    }

    public func eyes(at time: Int) -> MascotEyes {
        let local = time - start
        return eyes.last { $0.at <= local }?.eyes ?? baseEyes
    }

    /// 這段的補間全部結束的時間（絕對時間）；之後姿勢不再變（持續的晃動、呼吸由參數乘上時間函式，另外計算）
    public var settledAt: Int {
        let last = tweens.map { $0.at + $0.duration }.max() ?? 0
        let lastEyes = eyes.map(\.at).max() ?? 0
        return start + max(last, lastEyes)
    }

    /// 依絕對時間排序補間（`to` 可以不依時間順序呼叫）
    public mutating func finalize() {
        tweens = tweens.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        eyes.sort { $0.at < $1.at }
    }
}
