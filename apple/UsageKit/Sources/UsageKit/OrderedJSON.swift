import Foundation

/// 保留鍵順序與原始寫法的 JSON（ADR-0017 第 3 節）：改使用者的 `~/.claude/settings.json`、`~/.codex/hooks.json`
/// 時只動 `hooks` 底下我們的項目，其他鍵的順序、字串的跳脫寫法、數字的寫法都照原樣（只有縮排會變成 2 個空白）。
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    /// 字串：`raw` 是引號之間的原始寫法（含跳脫），`value` 是解開後的值
    case string(raw: String, value: String)
    /// 數字的原始寫法
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    public enum ParseError: Error, Equatable {
        case invalid(offset: Int)
        case tooDeep
    }

    /// 新的字串值（輸出時照 JSON 規則跳脫）
    public static func text(_ value: String) -> OrderedJSON {
        .string(raw: String(AgentHookMessage.quote(value).dropFirst().dropLast()), value: value)
    }

    public var stringValue: String? {
        if case .string(_, let value) = self { return value }
        return nil
    }

    public var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var elements: [OrderedJSON]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    public subscript(key: String) -> OrderedJSON? {
        members?.last { $0.key == key }?.value
    }

    // MARK: - 解析

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipSpace()
        // 允許 UTF-8 BOM
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3; parser.skipSpace() }
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError.invalid(offset: parser.index) }
        return value
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 200

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail() -> ParseError { .invalid(offset: index) }

        mutating func expect(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw fail() }
            index += expected.count
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < Self.maxDepth else { throw ParseError.tooDeep }
            guard index < bytes.count else { throw fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
                    let (_, key) = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    members.append(Member(key, try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [OrderedJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                while true {
                    skipSpace()
                    elements.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                    throw fail()
                }
            case UInt8(ascii: "\""):
                let (raw, value) = try string()
                return .string(raw: raw, value: value)
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default:
                return .number(try number())
            }
        }

        /// 讀一個字串：回傳引號之間的原始寫法與解開後的值（用 JSONSerialization 解跳脫，規則與系統一致）
        mutating func string() throws -> (String, String) {
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard let raw = String(data: Data(bytes[start + 1..<index - 1]), encoding: .utf8),
                          let decoded = try? JSONSerialization.jsonObject(with: Data("[".utf8) + token + Data("]".utf8)) as? [String],
                          let value = decoded.first else { throw ParseError.invalid(offset: start) }
                    return (raw, value)
                case 0x00..<0x20: throw fail()
                default: index += 1
                }
            }
            throw fail()
        }

        mutating func number() throws -> String {
            let start = index
            let allowed = Set("+-0123456789.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            guard index > start, let text = String(data: Data(bytes[start..<index]), encoding: .utf8),
                  (try? JSONSerialization.jsonObject(with: Data("[\(text)]".utf8))) != nil else { throw ParseError.invalid(offset: start) }
            return text
        }
    }

    // MARK: - 輸出

    /// 2 個空白縮排，結尾換行
    public func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        return Data((out + "\n").utf8)
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1), close = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += pad + AgentHookMessage.quote(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += i < members.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        case .array(let elements):
            guard !elements.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, element) in elements.enumerated() {
                out += pad
                element.write(into: &out, indent: indent + 1)
                out += i < elements.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case .string(let raw, _): out += "\"\(raw)\""
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }
}
