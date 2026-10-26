import Foundation

/// A CBOR value (RFC 8949), covering what CTAP2 and MS-RDPEWA use: definite
/// lengths only. Encoding is canonical (CTAP2 §6: shortest integers, map keys
/// sorted by their encoded bytes, shorter first), which authenticators require.
public indirect enum CBOR: Hashable, Sendable {
    case unsigned(UInt64)
    /// The integer `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null
    case undefined
    case float(Double)
    case tagged(UInt64, CBOR)

    public enum DecodingError: Error, Equatable {
        case truncated
        case unsupported(UInt8)
        case invalidText
        case tooDeep
        case trailingBytes
    }

    // MARK: Access

    public subscript(key: CBOR) -> CBOR? {
        if case let .map(m) = self { m[key] } else { nil }
    }

    public subscript(key: String) -> CBOR? { self[.text(key)] }
    public subscript(key: Int) -> CBOR? { self[CBOR(key)] }

    /// Looks up a text key ignoring case (MS-RDPEWA examples and implementations disagree on it).
    public func value(forCaseInsensitiveKey key: String) -> CBOR? {
        guard case let .map(m) = self else { return nil }
        return m.first { if case let .text(k) = $0.key { k.caseInsensitiveCompare(key) == .orderedSame } else { false } }?.value
    }

    public var uint: UInt64? { if case let .unsigned(v) = self { v } else { nil } }
    public var int: Int? {
        switch self {
        case let .unsigned(v): Int(exactly: v)
        case let .negative(v): Int(exactly: v).map { -1 - $0 }
        default: nil
        }
    }
    public var data: Data? { if case let .bytes(v) = self { v } else { nil } }
    public var string: String? { if case let .text(v) = self { v } else { nil } }
    public var boolValue: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var arrayValue: [CBOR]? { if case let .array(v) = self { v } else { nil } }
    public var mapValue: [CBOR: CBOR]? { if case let .map(v) = self { v } else { nil } }

    public init(_ value: Int) {
        self = value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value))
    }

    // MARK: Encoding

    public var encoded: Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case let .unsigned(v): Self.head(0, v, into: &out)
        case let .negative(v): Self.head(1, v, into: &out)
        case let .bytes(v):
            Self.head(2, UInt64(v.count), into: &out)
            out.append(v)
        case let .text(v):
            let utf8 = Data(v.utf8)
            Self.head(3, UInt64(utf8.count), into: &out)
            out.append(utf8)
        case let .array(v):
            Self.head(4, UInt64(v.count), into: &out)
            for item in v { item.encode(into: &out) }
        case let .map(v):
            Self.head(5, UInt64(v.count), into: &out)
            let entries = v.map { (key: $0.key.encoded, value: $0.value.encoded) }
            for entry in entries.sorted(by: { Self.canonicallyPrecedes($0.key, $1.key) }) {
                out.append(entry.key)
                out.append(entry.value)
            }
        case let .bool(v): out.append(v ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        case .undefined: out.append(0xF7)
        case let .float(v):
            out.append(0xFB)
            withUnsafeBytes(of: v.bitPattern.bigEndian) { out.append(contentsOf: $0) }
        case let .tagged(tag, v):
            Self.head(6, tag, into: &out)
            v.encode(into: &out)
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64, into out: inout Data) {
        let m = major << 5
        switch value {
        case ..<24: out.append(m | UInt8(value))
        case ...0xFF: out.append(contentsOf: [m | 24, UInt8(value)])
        case ...0xFFFF:
            out.append(m | 25)
            withUnsafeBytes(of: UInt16(value).bigEndian) { out.append(contentsOf: $0) }
        case ...0xFFFF_FFFF:
            out.append(m | 26)
            withUnsafeBytes(of: UInt32(value).bigEndian) { out.append(contentsOf: $0) }
        default:
            out.append(m | 27)
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
    }

    private static func canonicallyPrecedes(_ a: Data, _ b: Data) -> Bool {
        a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
    }

    // MARK: Decoding

    /// Decodes exactly one value occupying all of `data`.
    public static func decode(_ data: Data) throws -> CBOR {
        let (value, used) = try decodePrefix(data)
        guard used == data.count else { throw DecodingError.trailingBytes }
        return value
    }

    /// Decodes one value from the start of `data`, returning it and the bytes it used.
    public static func decodePrefix(_ data: Data) throws -> (CBOR, Int) {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.value(depth: 0)
        return (value, reader.offset)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodingError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func take(_ n: UInt64) throws -> [UInt8] {
            guard n <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
            defer { offset += Int(n) }
            return Array(bytes[offset..<offset + Int(n)])
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case ..<24: return UInt64(info)
            case 24...27:
                return try take(1 << (info - 24)).reduce(0) { $0 << 8 | UInt64($1) }
            default: throw DecodingError.unsupported(info) // indefinite lengths
            }
        }

        mutating func value(depth: Int) throws -> CBOR {
            guard depth < 32 else { throw DecodingError.tooDeep }
            let initial = try byte()
            let major = initial >> 5, info = initial & 0x1F
            if major == 7 { return try simple(info) }
            let arg = try argument(info)
            switch major {
            case 0: return .unsigned(arg)
            case 1: return .negative(arg)
            case 2: return .bytes(Data(try take(arg)))
            case 3:
                guard let s = String(bytes: try take(arg), encoding: .utf8) else { throw DecodingError.invalidText }
                return .text(s)
            case 4:
                guard arg <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
                return .array(try (0..<arg).map { _ in try value(depth: depth + 1) })
            case 5:
                guard arg <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
                var map: [CBOR: CBOR] = [:]
                for _ in 0..<arg {
                    let key = try value(depth: depth + 1)
                    map[key] = try value(depth: depth + 1)
                }
                return .map(map)
            default: // 6
                return .tagged(arg, try value(depth: depth + 1))
            }
        }

        mutating func simple(_ info: UInt8) throws -> CBOR {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            case 25: return .float(Self.half(UInt16(try argument(25))))
            case 26: return .float(Double(Float(bitPattern: UInt32(try argument(26)))))
            case 27: return .float(Double(bitPattern: try argument(27)))
            default: throw DecodingError.unsupported(0xE0 | info)
            }
        }

        static func half(_ bits: UInt16) -> Double {
            let exponent = Int(bits >> 10 & 0x1F), mantissa = Double(bits & 0x3FF)
            let sign: Double = bits & 0x8000 == 0 ? 1 : -1
            switch exponent {
            case 0: return sign * mantissa * pow(2, -24)
            case 31: return mantissa == 0 ? sign * .infinity : .nan
            default: return sign * (1 + mantissa / 1024) * pow(2, Double(exponent - 15))
            }
        }
    }
}

extension CBOR: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: CBOR...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (CBOR, CBOR)...) {
        self = .map(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
