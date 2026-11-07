import Core
import Foundation

/// Reads what a Codable type's JSON looks like by decoding one from a fake decoder that notes every key it's asked for,
/// so the schema can't drift from the types. An enum says its cases through CaseIterable; one that doesn't is a failure,
/// named in `failures`, not a hole in the schema.
final class SchemaWalker {
    var schemas: [String: JSONValue] = [:], failures: [String] = []
    private var open = Set<String>()
    let comments: [String: String]
    init(comments: [String: String]) { self.comments = comments }

    private let leaves: [ObjectIdentifier: (sample: Any, shape: JSONValue)] = {
        func type(_ t: String) -> JSONValue { .object(["type": .string(t)]) }
        return [
            ObjectIdentifier(String.self): ("", type("string")), ObjectIdentifier(Bool.self): (false, type("boolean")),
            ObjectIdentifier(Int.self): (0, type("integer")), ObjectIdentifier(Int32.self): (Int32(0), type("integer")),
            ObjectIdentifier(Int64.self): (Int64(0), type("integer")),
            ObjectIdentifier(UInt64.self): (UInt64(0), type("integer")),
            ObjectIdentifier(Double.self): (0.0, type("number")),
            ObjectIdentifier(Date.self): (
                Date(), .object(["type": .string("number"), "format": .string("seconds-since-2001")])
            ),
            ObjectIdentifier(Data.self): (
                Data(), .object(["type": .string("string"), "contentEncoding": .string("base64")])
            ),
            ObjectIdentifier(URL.self): (URL(fileURLWithPath: "/"), type("string")),
            ObjectIdentifier(JSONValue.self): (JSONValue.null, .object([:])),
            ObjectIdentifier(Done.self): (Done(), type("null"))
        ]
    }()

    static func name(_ t: Any.Type) -> String {
        String(reflecting: t).split(separator: ".").dropFirst().joined(separator: ".")
    }

    /// A named type goes in `schemas` once and is referred to, so a type that holds itself ends.
    func schema<T: Decodable>(_ t: T.Type) -> JSONValue {
        if let leaf = leaves[ObjectIdentifier(t)] { return leaf.shape }
        if let c = t as? any Container.Type { return c.shape(self) }
        let name = Self.name(t)
        if schemas[name] == nil, open.insert(name).inserted { schemas[name] = described(named(t), name) }
        return .object(["$ref": .string("#/components/schemas/\(name)")])
    }

    private func named<T: Decodable>(_ t: T.Type) -> JSONValue {
        if let c = t as? any CaseIterable.Type {
            let raws = (c.allCases as any Collection).map {
                ($0 as? any RawRepresentable).map { "\($0.rawValue)" } ?? ""
            }
            let isInt = raws.allSatisfy { Int($0) != nil }
            return .object([
                "type": .string(isInt ? "integer" : "string"),
                "enum": .array(raws.map { isInt ? .int(Int($0) ?? 0) : .string($0) })
            ])
        }
        let f = fields(of: t)
        if let single = f.single, f.props.isEmpty { return single }
        let props = f.props.reduce(into: [String: JSONValue]()) {
            $0[$1.key] = described($1.value, "\(Self.name(t)).\($1.key)")
        }
        return .object([
            "type": .string("object"), "properties": .object(props),
            "required": .array(f.required.sorted().map { .string($0) })
        ])
    }

    func fields<T: Decodable>(of t: T.Type) -> Record {
        let r = Record()
        do { _ = try T(from: SpyDecoder(walker: self, record: r)) } catch {
            failures.append("\(Self.name(t)): \(error)")
        }
        return r
    }

    func sample<T: Decodable>(_ t: T.Type) throws -> T {
        var v: Any?
        if let leaf = leaves[ObjectIdentifier(t)] {
            v = leaf.sample
        } else if let c = t as? any Container.Type {
            v = c.empty
        } else if let c = t as? any CaseIterable.Type {
            v = (c.allCases as any Collection).first
        }
        if let v {
            guard let typed = v as? T else { throw Unread.type(Self.name(t)) }
            return typed
        }
        return try T(from: SpyDecoder(walker: self, record: Record()))
    }

    func described(_ shape: JSONValue, _ key: String) -> JSONValue {
        guard case .object(var o) = shape, let text = comments[key] else { return shape }
        o["description"] = .string(text)
        return .object(o)
    }
}

enum Unread: Error { case type(String), nested(String) }

/// What one type's decoding asked for.
final class Record {
    var props: [String: JSONValue] = [:], required = Set<String>(), optional = Set<String>(), single: JSONValue?
}

/// What holds another type: its shape comes from the type, and it's empty on the way through, which is what ends a type
/// that holds itself.
protocol Container {
    static var empty: Self { get }
    static func shape(_ w: SchemaWalker) -> JSONValue
}
extension Array: Container where Element: Decodable {
    static var empty: Self { [] }
    static func shape(_ w: SchemaWalker) -> JSONValue {
        .object(["type": .string("array"), "items": w.schema(Element.self)])
    }
}
extension Set: Container where Element: Decodable {
    static var empty: Self { [] }
    static func shape(_ w: SchemaWalker) -> JSONValue {
        .object(["type": .string("array"), "items": w.schema(Element.self)])
    }
}
extension Dictionary: Container where Key: Decodable, Value: Decodable {
    static var empty: Self { [:] }
    /// Keys other than strings and numbers go as a list: key, value, key, value.
    static func shape(_ w: SchemaWalker) -> JSONValue {
        guard Key.self == String.self || Key.self == Int.self else {
            return .object(["type": .string("array"), "items": .object([:])])
        }
        return .object(["type": .string("object"), "additionalProperties": w.schema(Value.self)])
    }
}
extension Optional: Container where Wrapped: Decodable {
    static var empty: Self { nil }
    static func shape(_ w: SchemaWalker) -> JSONValue { w.schema(Wrapped.self) }
}

private struct SpyDecoder: Decoder {
    let walker: SchemaWalker, record: Record
    var codingPath: [any CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]
    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(SpyKeyed<Key>(walker: walker, record: record))
    }
    func unkeyedContainer() -> any UnkeyedDecodingContainer { SpyUnkeyed() }
    func singleValueContainer() -> any SingleValueDecodingContainer { SpySingle(walker: walker, record: record) }
}

private struct SpySingle: SingleValueDecodingContainer {
    let walker: SchemaWalker, record: Record
    var codingPath: [any CodingKey] = []
    func decodeNil() -> Bool { false }
    func decode<T: Decodable>(_ t: T.Type) throws -> T {
        record.single = walker.schema(t)
        return try walker.sample(t)
    }
}

private struct SpyUnkeyed: UnkeyedDecodingContainer {
    var codingPath: [any CodingKey] = [], count: Int? = 0, currentIndex = 0
    var isAtEnd: Bool { true }
    mutating func decodeNil() -> Bool { false }
    mutating func decode<T: Decodable>(_ t: T.Type) throws -> T { throw Unread.nested("\(T.self)") }
    mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type) throws -> KeyedDecodingContainer<N> {
        throw Unread.nested("unkeyed")
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { throw Unread.nested("unkeyed") }
    mutating func superDecoder() throws -> any Decoder { throw Unread.nested("unkeyed") }
}

private struct SpyKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let walker: SchemaWalker, record: Record
    var codingPath: [any CodingKey] = [], allKeys: [Key] = []
    func contains(_ key: Key) -> Bool { true }
    /// Only `decodeIfPresent` asks, for the types it has an overload of (String, Int…), and then calls `decode`.
    func decodeNil(forKey key: Key) -> Bool {
        record.optional.insert(key.stringValue)
        return false
    }
    func decode<T: Decodable>(_ t: T.Type, forKey key: Key) throws -> T {
        record.props[key.stringValue] = walker.schema(t)
        if !(t is any ExpressibleByNilLiteral.Type), !record.optional.contains(key.stringValue) {
            record.required.insert(key.stringValue)
        }
        return try walker.sample(t)
    }
    func decodeIfPresent<T: Decodable>(_ t: T.Type, forKey key: Key) throws -> T? {
        record.props[key.stringValue] = walker.schema(t)
        return nil
    }
    func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
        throw Unread.nested(key.stringValue)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw Unread.nested(key.stringValue)
    }
    func superDecoder() throws -> any Decoder { throw Unread.nested("super") }
    func superDecoder(forKey key: Key) throws -> any Decoder { throw Unread.nested(key.stringValue) }
}
