import Foundation

/// Minimal JSON tree used for JSON-RPC params/results.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Most common first: every miss throws (and builds) a DecodingError. Int stays before Double, so 3 stays an int.
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else {
            self = .array(try c.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var int: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    /// An int or a double (JSON doesn't tell 3 from 3.0).
    public var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    /// Encode any Encodable into a JSONValue.
    public static func from<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }
    public func decode<T: Decodable>(_ t: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
