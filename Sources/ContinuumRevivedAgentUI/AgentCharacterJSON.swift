import Foundation

// Plan: .plans/110-agent-characters/README.md (slice 1)
/// A JSON value that keeps object keys in the order JavaScript's `JSON.parse`
/// would enumerate them.
///
/// The theme validator reports the FIRST eight problems, so which eight depends on
/// the order it walks a palette or a helper's colours. Foundation's
/// `JSONSerialization` hands back an unordered dictionary, and it reads `true` as
/// the number 1, which the format must reject for `"duckherdTheme"`. Parity with
/// the reference parser (the corpus in CoreChecks) needs neither surprise.
enum AgentCharacterJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentCharacterJSON])
    /// Keys in enumeration order: array-index-like keys ascending, then the rest in
    /// first-insertion order. A repeated key keeps its first place and its last
    /// value, as `JSON.parse` does.
    case object([(key: String, value: AgentCharacterJSON)])

    static func == (lhs: AgentCharacterJSON, rhs: AgentCharacterJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    subscript(key: String) -> AgentCharacterJSON? {
        guard case let .object(entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    var isObject: Bool { if case .object = self { return true } else { return false } }
    var arrayValue: [AgentCharacterJSON]? { if case let .array(a) = self { return a } else { return nil } }
    var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    var numberValue: Double? { if case let .number(n) = self { return n } else { return nil } }
    /// `Number.isInteger`: a finite number with no fractional part.
    var integerValue: Int? {
        guard case let .number(n) = self, n.isFinite, n.rounded() == n, abs(n) < 1e15 else { return nil }
        return Int(n)
    }

    struct ParseError: Error {}

    static func parse(_ text: String) throws -> AgentCharacterJSON {
        var reader = Reader(scalars: Array(text.unicodeScalars))
        reader.skipWhitespace()
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        guard reader.atEnd else { throw ParseError() }
        return value
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0
        var atEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw ParseError() }
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> AgentCharacterJSON {
            // The format nests five deep; a pathological file must not exhaust the stack.
            guard depth < 64, index < scalars.count else { throw ParseError() }
            switch scalars[index] {
            case "{": return try object(depth: depth)
            case "[": return try array(depth: depth)
            case "\"": return .string(try string())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> AgentCharacterJSON {
            index += 1
            var indexKeys: [(index: UInt32, key: String)] = []
            var otherKeys: [String] = []
            var values: [String: AgentCharacterJSON] = [:]
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"" else { throw ParseError() }
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let item = try value(depth: depth + 1)
                if values.updateValue(item, forKey: key) == nil {
                    if let arrayIndex = Self.arrayIndex(key) {
                        indexKeys.append((arrayIndex, key))
                    } else {
                        otherKeys.append(key)
                    }
                }
                skipWhitespace()
                guard index < scalars.count else { throw ParseError() }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; break }
                throw ParseError()
            }
            let ordered = indexKeys.sorted { $0.index < $1.index }.map(\.key) + otherKeys
            return .object(ordered.map { (key: $0, value: values[$0]!) })
        }

        /// A canonical array index ("0", "17", never "07"), which JavaScript lists first.
        static func arrayIndex(_ key: String) -> UInt32? {
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  key == "0" || !key.hasPrefix("0"), let value = UInt32(key), value < UInt32.max else { return nil }
            return value
        }

        mutating func array(depth: Int) throws -> AgentCharacterJSON {
            index += 1
            var items: [AgentCharacterJSON] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array([]) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < scalars.count else { throw ParseError() }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; break }
                throw ParseError()
            }
            return .array(items)
        }

        mutating func string() throws -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while true {
                guard index < scalars.count else { throw ParseError() }
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"": return String(out)
                case "\\":
                    guard index < scalars.count else { throw ParseError() }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        let unit = try hex4()
                        if (0xD800...0xDBFF).contains(unit), index + 1 < scalars.count,
                           scalars[index] == "\\", scalars[index + 1] == "u" {
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw ParseError() }
                            let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            guard let s = Unicode.Scalar(combined) else { throw ParseError() }
                            out.append(s)
                        } else {
                            // A lone surrogate is legal JSON but not a Swift string.
                            guard let s = Unicode.Scalar(UInt32(unit)) else { throw ParseError() }
                            out.append(s)
                        }
                    default: throw ParseError()
                    }
                default:
                    guard scalar.value >= 0x20 else { throw ParseError() }
                    out.append(scalar)
                }
            }
        }

        mutating func hex4() throws -> UInt16 {
            guard index + 4 <= scalars.count else { throw ParseError() }
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard scalars[index].properties.isASCIIHexDigit,
                      let digit = UInt16(String(scalars[index]), radix: 16) else { throw ParseError() }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func number() throws -> Double {
            let start = index
            if index < scalars.count, scalars[index] == "-" { index += 1 }
            guard index < scalars.count, ("0"..."9").contains(scalars[index]) else { throw ParseError() }
            if scalars[index] == "0" {
                index += 1
            } else {
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            }
            if index < scalars.count, scalars[index] == "." {
                index += 1
                guard index < scalars.count, ("0"..."9").contains(scalars[index]) else { throw ParseError() }
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                index += 1
                if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
                guard index < scalars.count, ("0"..."9").contains(scalars[index]) else { throw ParseError() }
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[start..<index])
            guard let value = Double(text) else { throw ParseError() }
            return value
        }
    }
}
