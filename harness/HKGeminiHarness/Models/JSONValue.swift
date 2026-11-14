import Foundation

/// A loss-free, Codable representation of arbitrary JSON.
///
/// Used wherever the shape is not fixed in advance: unknown CSV columns kept for forward
/// compatibility, HealthKit metadata, raw Gemini request/response bodies, and the JSON schema
/// sent to the model. Numbers stay `Double`; integers are recognised on output when exact.
public enum JSONValue: Codable, Equatable, Hashable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Convenience accessors

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var intValue: Int? { doubleValue.flatMap { $0 == $0.rounded() ? Int($0) : nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    public var description: String {
        guard let data = try? JSONValue.encoder(pretty: false).encode(self),
              let s = String(data: data, encoding: .utf8) else { return "<invalid json>" }
        return s
    }

    // MARK: Building from Swift values

    public init(_ any: Any?) {
        switch any {
        case nil: self = .null
        case let v as JSONValue: self = v
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let i as Int64: self = .number(Double(i))
        case let f as Float: self = f.isFinite ? .number(Double(f)) : .null
        case let d as Double: self = d.isFinite ? .number(d) : .null
        case let s as String: self = .string(s)
        case let date as Date: self = .string(ISO8601.string(from: date))
        case let a as [Any?]: self = .array(a.map { JSONValue($0) })
        case let a as [Any]: self = .array(a.map { JSONValue($0) })
        case let o as [String: Any?]: self = .object(o.mapValues { JSONValue($0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue($0) })
        case let n as NSNumber: self = .number(n.doubleValue)
        default: self = .string(String(describing: any!))
        }
    }

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Accepts ISO 8601 with or without fractional seconds (FaceMetrics writes without; this module
    /// writes with). The stock `.iso8601` strategy rejects fractional seconds.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISO8601.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        return d
    }

    /// Encodes any Encodable into a JSONValue tree (round trip through Data).
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder(pretty: false).encode(value)
        return try decoder().decode(JSONValue.self, from: data)
    }

    /// nil becomes `.null` instead of relying on top-level-fragment support in JSONEncoder.
    public static func from<T: Encodable>(_ value: T?) throws -> JSONValue {
        guard let value else { return .null }
        return try from(value)
    }

    public func prettyString() -> String {
        guard let data = try? JSONValue.encoder(pretty: true).encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Every finite number anywhere in the tree. Used by the response validator to check that the
    /// model did not invent numbers that were not in the request.
    public func allNumbers() -> [Double] {
        var out: [Double] = []
        collectNumbers(into: &out)
        return out
    }

    private func collectNumbers(into out: inout [Double]) {
        switch self {
        case .number(let d): out.append(d)
        case .array(let a): for v in a { v.collectNumbers(into: &out) }
        case .object(let o): for v in o.values { v.collectNumbers(into: &out) }
        case .string(let s):
            // Numbers embedded in strings (e.g. "62.5 ms") count as well.
            for m in NumberScanner.numbers(in: s) { out.append(m) }
        default: break
        }
    }
}

/// ISO 8601 with fractional seconds, UTC. One shared formatter for the whole module.
public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(from date: Date) -> String { withFraction.string(from: date) }

    public static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}

/// Finds decimal numbers inside free text. Shared by the validator and the JSON walker.
public enum NumberScanner {
    private static let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z_])[-+]?\d+(?:[.,]\d+)?(?![A-Za-z_\d])"#)

    public static func numbers(in text: String) -> [Double] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Double(ns.substring(with: m.range).replacingOccurrences(of: ",", with: "."))
        }
    }
}
