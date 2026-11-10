import Core
import Foundation
import Testing

@testable import Daemon

/// rpc.json is what `kelp schema` shows and other clients are generated from. New methods and fields go in with
/// `KELP_WRITE_SCHEMA=1 swift test --filter rpcSchema`, which also refreshes the descriptions; a field that went or changed
/// isn't written: an older app and people's scripts still rely on it. A change that really is meant goes in by hand.
@Test func rpcSchemaOnlyGrows() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let file = root.appendingPathComponent("Sources/Core/Resources/rpc.json")
    let walker = SchemaWalker(comments: try sourceComments(in: root.appendingPathComponent("Sources/Core")))
    let now = document(walker)
    let old = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(walker.failures == [], "a type the schema can't read: an enum needs CaseIterable")
    let broken = breaks(old, now)
    #expect(broken == [], "gone or changed: clients still rely on these")
    if ProcessInfo.processInfo.environment["KELP_WRITE_SCHEMA"] != nil, broken.isEmpty, walker.failures.isEmpty {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (e.encode(now) + Data("\n".utf8)).write(to: file)
    } else {
        #expect(
            undescribed(old) == undescribed(now),
            "the schema changed: KELP_WRITE_SCHEMA=1 swift test --filter rpcSchema")
    }
}

private func document(_ w: SchemaWalker) -> JSONValue {
    let methods = Daemon.methods.values.sorted { $0.name < $1.name }.map { method($0, w) }
    let events = rpcEvents.sorted { $0.name < $1.name }.map { event($0, w) }
    return .object([
        "openrpc": "1.3.2",
        "info": .object(["title": "Kelp daemon", "version": "1.0.0", "description": .string(transport)]),
        "methods": .array(methods), "components": .object(["schemas": .object(w.schemas)]), "x-events": .array(events)
    ])
}

private let transport =
    "JSON-RPC 2.0, one message a line, over the Unix socket at ~/.kelp/kelp.sock. A method marked x-internal is for Kelp's "
    + "own window and tools: it gets no promise. Events are notifications: x-events lists them, and sets up none of them."

private func method<M: RPCMethod>(_ m: M.Type, _ w: SchemaWalker) -> JSONValue {
    let f = w.fields(of: m), name = SchemaWalker.name(m)
    let params: [JSONValue] = f.props.sorted { $0.key < $1.key }.map { key, shape in
        var o: [String: JSONValue] = [
            "name": .string(key), "required": .bool(f.required.contains(key)), "schema": shape
        ]
        if let text = w.comments["\(name).\(key)"] { o["description"] = .string(text) }
        return .object(o)
    }
    var o: [String: JSONValue] = [
        "name": .string(m.name), "paramStructure": "by-name", "params": .array(params),
        "result": .object(["name": "result", "schema": w.schema(M.Result.self)])
    ]
    if let text = w.comments[name] { o["description"] = .string(text) }
    if m is any InternalMethod.Type { o["x-internal"] = true }
    return .object(o)
}

private func event<E: RPCEvent>(_ e: E.Type, _ w: SchemaWalker) -> JSONValue {
    var o: [String: JSONValue] = ["name": .string(e.name), "params": w.schema(e)]
    if let text = w.comments[SchemaWalker.name(e)] { o["description"] = .string(text) }
    return .object(o)
}

/// The `///` comments of Core's types and fields, by "Type.Nested.field". Indentation says what's inside what.
func sourceComments(in folder: URL) throws -> [String: String] {
    var found: [String: String] = [:]
    let declaration = /(?:(?:public|private|package|final|indirect) )*(struct|enum|class|extension) (\w+)/
    let field = /(?:public )?(?:var|let|case) (\w+)/
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
    for file in files ?? [] where file.pathExtension == "swift" {
        var doc: [String] = [], inside: [(indent: Int, name: String)] = []
        for line in try String(contentsOf: file, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            let text = line.trimmingCharacters(in: .whitespaces), indent = line.prefix { $0 == " " }.count
            guard !text.isEmpty else {
                doc = []
                continue
            }
            if text.hasPrefix("///") {
                doc.append(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                continue
            }
            while let top = inside.last, indent <= top.indent { inside.removeLast() }
            if let m = text.prefixMatch(of: declaration) {
                inside.append((indent, String(m.2)))
                if !doc.isEmpty, m.1 != "extension" {
                    found[inside.map(\.name).joined(separator: ".")] = doc.joined(separator: " ")
                }
            } else if let m = text.prefixMatch(of: field), !doc.isEmpty, !inside.isEmpty {
                found[(inside.map(\.name) + [String(m.1)]).joined(separator: ".")] = doc.joined(separator: " ")
            }
            doc = []
        }
    }
    return found
}

/// What a client of `old` would notice in `new`. Adding is fine: a method, a field, an optional param, an enum's case.
func breaks(_ old: JSONValue, _ new: JSONValue) -> [String] {
    var out: [String] = []
    func named(_ v: JSONValue?) -> [String: JSONValue] {
        (v?.array ?? []).reduce(into: [:]) { if let n = $1["name"]?.string { $0[n] = $1 } }
    }
    for (name, m) in named(old["methods"]) {
        guard let n = named(new["methods"])[name] else {
            out.append("\(name): gone")
            continue
        }
        let was = named(m["params"]), now = named(n["params"])
        for (p, v) in was { compare(v["schema"], now[p]?["schema"], "\(name)(\(p))", &out) }
        for (p, v) in now where v["required"]?.bool == true && was[p]?["required"]?.bool != true {
            out.append("\(name)(\(p)): now required")
        }
        compare(m["result"]?["schema"], n["result"]?["schema"], "\(name) →", &out)
    }
    for (name, e) in named(old["x-events"]) {
        guard let n = named(new["x-events"])[name] else {
            out.append("\(name): gone")
            continue
        }
        compare(e["params"], n["params"], name, &out)
    }
    if case .object(let was)? = old["components"]?["schemas"] {
        for (name, s) in was { compare(s, new["components"]?["schemas"]?[name], name, &out) }
    }
    return out.sorted()
}

private func compare(_ old: JSONValue?, _ new: JSONValue?, _ path: String, _ out: inout [String]) {
    guard case .object(let o)? = old else { return }
    guard let new else {
        out.append("\(path): gone")
        return
    }
    for key in ["type", "$ref", "format", "contentEncoding"] where o[key] != new[key] {
        out.append("\(path): was \(o[key]?.string ?? "untyped")")
    }
    if let cases = o["enum"]?.array {
        for c in cases where new["enum"]?.array?.contains(c) != true { out.append("\(path): lost case \(c)") }
    }
    compare(o["items"], new["items"], "\(path)[]", &out)
    compare(o["additionalProperties"], new["additionalProperties"], "\(path){}", &out)
    if case .object(let props)? = o["properties"] {
        for (p, v) in props { compare(v, new["properties"]?[p], "\(path).\(p)", &out) }
    }
    for r in o["required"]?.array ?? [] where new["required"]?.array?.contains(r) != true {
        out.append("\(path).\(r.string ?? ""): no longer always there")
    }
}

/// Without the comments: a changed comment isn't a changed contract.
private func undescribed(_ v: JSONValue) -> JSONValue {
    switch v {
    case .object(let o): .object(o.filter { $0.key != "description" }.mapValues(undescribed))
    case .array(let a): .array(a.map(undescribed))
    default: v
    }
}

/// The two the first run got wrong, seen against a live daemon's replies: an optional String decodes through `decode`, not
/// `decodeIfPresent`, and a map with other keys is a list on the wire.
@Test func theSchemaSaysWhatTheEncoderWrites() throws {
    struct Inner: Codable, Equatable { var a: Int }
    struct Thing: Codable {
        var name: String, nick: String?, inner: Inner?, list: [Inner], byName: [String: Int], byPair: [Pair: Int],
            status: AgentStatus
    }
    struct Pair: Codable, Hashable { var a: Int }
    let w = SchemaWalker(comments: [:]), f = w.fields(of: Thing.self)
    #expect(w.failures == [])
    #expect(f.required == ["name", "list", "byName", "byPair", "status"])
    let thing = Thing(
        name: "", nick: "", inner: Inner(a: 1), list: [], byName: [:], byPair: [Pair(a: 1): 2], status: .idle)
    let wire = try JSONValue.from(thing)
    #expect(Set(f.props.keys) == Set(try #require(wire.objectKeys)))
    #expect(wire["byPair"]?.array?.count == 2)
    #expect(f.props["byPair"]?["type"] == "array")
    #expect(f.props["byName"]?["type"] == "object")
}

private extension JSONValue {
    var objectKeys: [String]? { if case .object(let o) = self { return Array(o.keys) } else { return nil } }
}

@Test func aClientsBreakIsNamed() {
    func doc(_ required: [String], _ field: String, _ type: String) -> JSONValue {
        let props: JSONValue = .object([field: .object(["type": .string(type)])])
        let s: JSONValue = .object([
            "type": "object", "required": .array(required.map { .string($0) }), "properties": props
        ])
        return .object([
            "methods": .array([.object(["name": "a.b", "params": .array([]), "result": .object(["schema": s])])])
        ])
    }
    #expect(breaks(doc(["x"], "x", "string"), doc(["x"], "x", "string")) == [])
    #expect(breaks(doc(["x"], "x", "string"), doc(["x"], "x", "integer")) == ["a.b →.x: was string"])
    #expect(breaks(doc(["x"], "x", "string"), doc([], "x", "string")) == ["a.b →.x: no longer always there"])
    #expect(breaks(doc([], "x", "string"), doc([], "y", "string")) == ["a.b →.x: gone"])
    #expect(breaks(doc([], "x", "string"), .object(["methods": .array([])])) == ["a.b: gone"])
}
