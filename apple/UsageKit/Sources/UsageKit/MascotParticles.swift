import Foundation

/// 固定種子的亂數（SplitMix64）：粒子、碎片與眨眼的時間由種子決定，同一個種子每次畫出一樣的畫面
public struct MascotRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// 近似高斯（三個均勻亂數相加，同 demo 的 gs()），約 -1～1
    public mutating func gaussian() -> Double {
        (unit() + unit() + unit() - 1.5) / 1.5
    }

    /// 由種子與編號算出的一次性亂數（眨眼、第 n 圈漣漪）
    public static func unit(seed: UInt64, index: UInt64) -> Double {
        var random = MascotRandom(seed: seed ^ (index &* 0xD6E8_FEB8_6659_FD93))
        return random.unit()
    }
}

/// 過場的漣漪粒子與碎片（MASCOT-SPEC 第 4 節）：每圈 560 顆、持續 1.7 秒、半徑 14 → 344；
/// 碰到面板左右邊緣時前兩圈在邊緣閃一條弧形光，只亮 0.32 秒。
public struct MascotRipple: Sendable {
    public struct Particle: Sendable {
        public var angle: Double
        public var jitter: Double
        public var size: Double
        public var phase: Double
        public var tinted: Bool
    }

    public struct Ring: Sendable {
        public var index: Int
        public var start: Int
        public var particles: [Particle]
        public var seed: Double
    }

    public struct Confetti: Sendable {
        public var angle: Double
        public var speed: Double
        public var rotation: Double
        public var spin: Double
        public var color: Int
    }

    public let config: MascotConfig.Ripple
    public let rings: [Ring]
    public let confetti: [Confetti]
    public let confettiStart: Int

    /// 過場在 `introStart` 開始；`ringsAt` 是每圈的時間（過場內）
    public init(config: MascotConfig.Ripple, introStart: Int, ringsAt: [Int], confettiAt: Int, seed: UInt64) {
        self.config = config
        var random = MascotRandom(seed: seed)
        rings = ringsAt.enumerated().map { index, at in
            let particles = (0..<config.particles).map { _ in
                Particle(angle: random.unit() * 2 * .pi, jitter: random.gaussian() * config.thicknessPx,
                         size: random.unit() * 1.1 + 0.45, phase: random.unit() * 2 * .pi,
                         tinted: random.unit() < config.tintFraction)
            }
            return Ring(index: index, start: introStart + at, particles: particles, seed: random.unit() * 9)
        }
        confetti = (0..<config.confetti.count).map { n in
            Confetti(angle: random.unit() * 2 * .pi,
                     speed: config.confetti.speedMin + random.unit() * config.confetti.speedSpan,
                     rotation: random.unit() * 6, spin: (random.unit() - 0.5) * 8, color: n % 5)
        }
        confettiStart = introStart + confettiAt
    }

    /// 某一圈在 `time` 的半徑與透明度；不在播放時間內為 nil
    public func ringState(_ ring: Ring, at time: Int) -> (radius: Double, fade: Double)? {
        guard time >= ring.start else { return nil }
        let u = Double(time - ring.start) / Double(config.durationMs)
        guard u < 1 else { return nil }
        let radius = config.radiusFrom + MascotEase.out(u) * config.radiusSpan
        let fade = (u < config.fadeIn ? u / config.fadeIn : 1) * (1 - u * u * 0.7)
        return (radius, fade)
    }

    /// 前兩圈碰到面板左右邊緣（距中心 `halfWidth - hitInset`）的時間；碰不到為 nil
    public func edgeHitTime(_ ring: Ring, halfWidth: Double) -> Int? {
        guard ring.index < config.edgeFlash.rings else { return nil }
        let needed = (halfWidth - config.edgeFlash.hitInsetPx - config.radiusFrom) / config.radiusSpan
        guard needed < 1 else { return nil }
        // EO(u) = 1 - (1-u)^3 = needed
        let u = needed <= 0 ? 0 : 1 - pow(1 - needed, 1.0 / 3.0)
        return ring.start + Int((u * Double(config.durationMs)).rounded(.up))
    }

    /// 邊緣弧光在 `time` 的透明度（只亮 0.32 秒）
    public func edgeFlashAlpha(at time: Int, halfWidth: Double) -> Double {
        var alpha = 0.0
        for ring in rings {
            guard let hit = edgeHitTime(ring, halfWidth: halfWidth), time >= hit, time < hit + config.edgeFlash.ms else { continue }
            let strength = ring.index < config.edgeFlash.alpha.count ? config.edgeFlash.alpha[ring.index] : 0
            alpha = max(alpha, sin(Double(time - hit) / Double(config.edgeFlash.ms) * .pi) * strength)
        }
        return alpha
    }

    /// 粒子、碎片都播完的時間：之後不再畫、也不再需要每秒 60 次
    public var endTime: Int {
        max(rings.map { $0.start + config.durationMs }.max() ?? 0, confettiStart + config.confetti.ms)
    }
}
