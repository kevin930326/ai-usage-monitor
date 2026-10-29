import Foundation

/// 角色外觀（ADR-0021）：`shared/mascot-looks.json` 的一個項目。預設「跟著服務」不在清單裡（用服務色，`nil`）。
/// 顏色是 0…255 的 sRGB 三元組，和 `MascotConfig.Tint` 相同。
public struct MascotLook: Decodable, Equatable, Identifiable, Sendable {
    public enum Style: String, Decodable, Sendable {
        /// 三階球面漸層（同服務色的畫法）
        case solid
        /// 直線漸層加高光與陰影
        case linear
        /// 特效：LED 點陣、8-bit 像素、霓虹線條、線框球、ASCII
        case led, pixel, neon, wire, ascii

        public var isEffect: Bool { self != .solid && self != .linear }
        /// 格子類特效（LED 點陣、8-bit 像素、ASCII）：18 pt 的選單列圖示上格子太粗、表情分不出來，改畫主色三階的實心球（ADR-0021 第 5 節）
        public var isGrid: Bool { self == .led || self == .pixel || self == .ascii }
        /// 會隨時間變化的特效（像素是靜態的格子，不用重畫）
        public var animates: Bool { self == .led || self == .neon || self == .wire || self == .ascii }
    }

    public var id: String
    public var name: String
    public var group: String
    public var style: Style
    public var light: [Double]?
    public var mid: [Double]?
    public var shade: [Double]?
    /// 直線漸層的顏色（style linear）
    public var stops: [[Double]]?
    /// 直線漸層的方向（度，0 是往右、90 是往下）
    public var angle: Double?
    /// 特效的主色
    public var color: [Double]?
    public var glow: [Double]
    /// 光暈的強度倍數（霓虹較強）
    public var glowScale: Double
    /// 眼睛的顏色；nil 是深色 #121212（深色身體用亮色）
    public var eye: [Double]?
    /// 可愛風的腮紅
    public var blush: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, group, style, light, mid, shade, stops, angle, color, glow, glowScale = "glow_scale", eye, blush
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func rgb(_ key: CodingKeys) throws -> [Double]? {
            try c.decodeIfPresent(String.self, forKey: key).map { try Self.rgb($0) }
        }
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        style = try c.decode(Style.self, forKey: .style)
        light = try rgb(.light)
        mid = try rgb(.mid)
        shade = try rgb(.shade)
        stops = try c.decodeIfPresent([String].self, forKey: .stops)?.map(Self.rgb)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle)
        color = try rgb(.color)
        glow = try Self.rgb(c.decode(String.self, forKey: .glow))
        glowScale = try c.decodeIfPresent(Double.self, forKey: .glowScale) ?? 1
        eye = try rgb(.eye)
        blush = try c.decodeIfPresent(Bool.self, forKey: .blush) ?? false
        let complete = switch style {
        case .solid: light != nil && mid != nil && shade != nil
        case .linear: (stops?.count ?? 0) >= 2
        default: color != nil
        }
        guard complete else {
            throw DecodingError.dataCorruptedError(forKey: .style, in: c, debugDescription: "\(id)：\(style.rawValue) 缺少顏色")
        }
    }

    /// 「#RRGGBB」→ [r, g, b]
    static func rgb(_ text: String) throws -> [Double] {
        let hex = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "顏色格式不對：\(text)"))
        }
        return [Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF)]
    }

    /// 特效主色的三階（同規格頁的 shade()：亮＝混白 60%、暗＝混黑 50%），手與像素的明暗用
    public var effectTint: (light: [Double], mid: [Double], shade: [Double])? {
        guard let color else { return nil }
        return (zip(color, [255.0, 255, 255]).map { $0 + ($1 - $0) * 0.6 }, color, color.map { $0 * 0.5 })
    }
}

/// `shared/mascot-looks.json` 整份
public struct MascotLooks: Decodable, Sendable {
    public struct Group: Decodable, Sendable, Identifiable {
        public var id: String
        public var name: String
    }

    public var version: Int
    public var groups: [Group]
    public var looks: [MascotLook]

    public static func decode(_ data: Data) throws -> MascotLooks {
        let file = try JSONDecoder().decode(MascotLooks.self, from: data)
        let ids = file.looks.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "外觀代號重複"))
        }
        let groups = Set(file.groups.map(\.id))
        if let stray = file.looks.first(where: { !groups.contains($0.group) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(stray.id) 的分組不存在"))
        }
        return file
    }

    public func look(_ id: String?) -> MascotLook? {
        id.flatMap { id in looks.first { $0.id == id } }
    }
}
