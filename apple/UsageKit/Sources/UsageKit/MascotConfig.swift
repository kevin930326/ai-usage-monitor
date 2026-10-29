import Foundation

/// `shared/mascot-anim.json` 的完整內容（ADR-0016 第 3 節）。Mac App 以資源檔打包；測試讀 repo 裡的這份。
/// 狀態機的部分另外解成 `MascotTiming`（鍵名不同的寫法，兩邊的 golden 測試共用）。
public struct MascotConfig: Sendable {
    public var timing: MascotTiming
    public var panel: Panel
    public var hero: Hero
    public var palette: Palette
    public var poses: Poses
    public var intro: Intro
    public var ripple: Ripple
    public var expressions: Expressions
    public var gestures: Gestures
    /// `machine` 裡狀態機以外的互動參數（停留多久害羞、單擊時隨機挑的短反應）
    public var interaction: Interaction

    public static func decode(_ data: Data) throws -> MascotConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(File.self, from: data)
        return MascotConfig(timing: try MascotTiming.decode(fromConfig: data), panel: file.panel, hero: file.hero,
                            palette: file.palette, poses: file.poses, intro: file.intro, ripple: file.ripple,
                            expressions: file.expressions, gestures: file.gestures, interaction: file.machine)
    }

    /// `#RRGGBB` → [r, g, b]（0～255）；格式不對時是黑色（設定檔由測試檢查）
    public static func rgb(_ hex: String) -> [Double] {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return [0, 0, 0] }
        return [Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF)]
    }

    private struct File: Decodable {
        var panel: Panel
        var hero: Hero
        var palette: Palette
        var poses: Poses
        var intro: Intro
        var ripple: Ripple
        var expressions: Expressions
        var gestures: Gestures
        var machine: Interaction
    }

    public struct Size: Decodable, Sendable { public var width: Double; public var height: Double; public var corner: Double }
    public struct Spring: Decodable, Sendable { public var stiffness: Double; public var dampingRatio: Double }
    public struct Point: Decodable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public init(x: Double, y: Double, radius: Double) {
            self.x = x
            self.y = y
            self.radius = radius
        }
    }
    public struct Padding: Decodable, Sendable { public var top: Double; public var side: Double; public var bottom: Double }

    public struct Panel: Decodable, Sendable {
        public var collapsed: Size
        public var expanded: Size
        public var cornerOvershootMax: Double
        public var openSpring: Spring
        public var closeSpring: Spring
        public var closeDelayMs: Int
        public var contentFadeOutMs: Int
        public var contentFadeInMs: Int
        public var contentRisePx: Double
        public var contentRiseMs: Int
        public var miniFadeFactor: Double
        public var stripHeight: Double
        public var stripTop: Double
        public var contentPadding: Padding
        public var characterCardWidth: Double
        public var cardCorner: Double
        public var alertBump: Bump
        public var closeGlideMs: Int

        public struct Bump: Decodable, Sendable {
            public var width: Double
            public var height: Double
            public var riseMs: Int
            public var holdMs: Int
            public var fallMs: Int
        }
    }

    public struct Hero: Decodable, Sendable {
        public var mini: Point
        public var card: Point
        public var intro: IntroPlace
        public var bodyHighlight: Highlight
        public var eye: Eye
        public var hand: Hand
        public var handRest: HandRest
        public var wave: Wave
        public var glow: Glow
        /// 擔心、難過、生病時的眉毛（額度與狀態改用表情表示，沒有狀態點）
        public var brow: Brow
        public var follow: Follow
        public var blink: Blink
        /// 工作中的鍵盤（展開與收合共用）
        public var keyboard: Keyboard

        public struct IntroPlace: Decodable, Sendable { public var x: Double; public var y: Double; public var radius: Double; public var startDrop: Double }
        public struct Highlight: Decodable, Sendable { public var x: Double; public var y: Double; public var radius: Double }
        public struct Eye: Decodable, Sendable { public var width: Double; public var height: Double; public var yaw: Double; public var pitch: Double }
        public struct Hand: Decodable, Sendable { public var radius: Double; public var depthScale: Double; public var popFrom: Double }
        public struct HandRest: Decodable, Sendable { public var left: [Double]; public var right: [Double] }
        public struct Wave: Decodable, Sendable { public var pivot: [Double]; public var radius: Double; public var angle: Double; public var swing: Double; public var periodMs: Double }
        public struct Glow: Decodable, Sendable { public var inner: Double; public var outer: Double; public var alpha: Double }
        public struct Brow: Decodable, Sendable {
            public var yaw: Double
            public var pitch: Double
            public var width: Double
            public var thickness: Double
            public var worriedTilt: Double
            public var sadTilt: Double
        }
        public struct Follow: Decodable, Sendable {
            public var yawMax: Double
            public var pitchMax: Double
            public var smoothingPerFrame: Double
            public var yawSpanPx: Double
            public var pitchSpanPx: Double
        }
        public struct Blink: Decodable, Sendable { public var minGapMs: Int; public var maxGapMs: Int; public var closeMs: Int; public var holdMs: Int; public var openMs: Int }
        public struct Keyboard: Decodable, Sendable {
            public var y: Double
            public var width: Double
            public var height: Double
            /// `#RRGGBB`
            public var color: String
            public var shine: Shine
            public var keys: Keys
            public struct Shine: Decodable, Sendable { public var x: Double; public var y: Double; public var width: Double; public var height: Double; public var alpha: Double }
            public struct Keys: Decodable, Sendable {
                public var count: Int
                public var x: Double
                public var step: Double
                public var y: Double
                public var width: Double
                public var height: Double
                public var color: String
                public var phase: Double
                public var onAbove: Double
            }
        }
    }

    public struct Tint: Decodable, Sendable {
        public var light: [Double]
        public var mid: [Double]
        public var shade: [Double]
        public var glow: [Double]
    }

    public struct Palette: Decodable, Sendable {
        public var white: Tint
        public var claude: Tint
        public var codex: Tint
        public var status: Status
        public struct Status: Decodable, Sendable { public var normal: [Double]; public var high: [Double]; public var out: [Double] }
    }

    public struct Poses: Decodable, Sendable {
        public var work: Work
        public var sleep: Sleep
        public var restMs: Int
        public var neutralMs: Int
        public var workMs: Int
        /// 需要你：右手舉高（收合的迷你角色也一樣）
        public var raise: Raise
        public var raiseMs: Int
        /// 收著時完成：迷你角色揮手多久
        public var cheerWaveMs: Int
        public struct Raise: Decodable, Sendable { public var pitch: Double; public var roll: Double; public var left: [Double]; public var right: [Double] }
        public struct Work: Decodable, Sendable { public var pitch: Double; public var follow: Double; public var left: [Double]; public var right: [Double] }
        public struct Sleep: Decodable, Sendable { public var pitch: Double; public var glow: Double; public var enterMs: Int }
    }

    public struct Intro: Decodable, Sendable {
        public var totalMs: Int
        public var startPitch: Double
        public var ringsAt: [Int]
        public var confettiAt: Int
        public var contentAt: Int
    }

    public struct Ripple: Decodable, Sendable {
        public var particles: Int
        public var durationMs: Int
        public var radiusFrom: Double
        public var radiusSpan: Double
        public var thicknessPx: Double
        public var edgeWobblePx: Double
        public var edgeWobbleLobes: Double
        public var verticalSquash: Double
        public var fadeIn: Double
        public var tintFraction: Double
        public var twinkleMs: Double
        public var edgeFadePx: Double
        public var edgeInsetPx: Double
        public var edgeFlash: Flash
        public var confetti: Confetti
        public struct Flash: Decodable, Sendable { public var rings: Int; public var ms: Int; public var alpha: [Double]; public var hitInsetPx: Double }
        public struct Confetti: Decodable, Sendable {
            public var count: Int
            public var ms: Int
            public var speedMin: Double
            public var speedSpan: Double
            public var xStretch: Double
            public var yStretch: Double
        }
    }

    public struct Expressions: Decodable, Sendable {
        public var collapsedAlert: CollapsedAlert
        public struct CollapsedAlert: Decodable, Sendable { public var ms: Int; public var hop: Double }
    }

    public struct Gestures: Decodable, Sendable {
        public var circleRadiusPx: Double
        public var circleSampleGapMs: Int
        public var circleDecayPerMove: Double
        public var circleTurns: Double
        public var shakeMinDxPx: Double
        public var shakeRadiusPx: Double
        public var shakeReversals: Int
        public var shakeResetMs: Int
        public var tapHitRadius: Double
    }

    public struct Interaction: Decodable, Sendable {
        public var hoverShyMs: Int
        /// 單擊時平均隨機挑的短反應
        public var tapReactions: [String]
    }
}
