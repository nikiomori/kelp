import Foundation

/// `kelp schema`: Resources/rpc.json, which Tests/DaemonTests/RPCSchemaTests.swift keeps in step with the types, as text.
public enum RPCSchema {
    /// All the methods, or what `query` names: a method, an event or a type, exactly or as the only name holding it.
    public static func text(_ doc: JSONValue, _ query: String? = nil) -> String {
        let methods = doc["methods"]?.array ?? [], events = doc["x-events"]?.array ?? []
        var types: [String: JSONValue] = [:]
        if case .object(let o)? = doc["components"]?["schemas"] { types = o }
        guard let query, !query.isEmpty else { return list(methods, events) }
        let q = query.lowercased()
        func name(_ v: JSONValue) -> String { v["name"]?.string ?? "" }
        let shown: [(name: String, text: () -> String)] =
            methods.map { m in (name(m), { method(m) }) } + events.map { e in (name(e), { event(e) }) }
            + types.keys.sorted().map { key in (key, { type(key, types[key] ?? .null) }) }
        if let hit = shown.first(where: { $0.name.lowercased() == q }) { return hit.text() }
        let close = shown.filter { $0.name.lowercased().contains(q) }
        if close.count == 1 { return close[0].text() }
        return close.isEmpty ? "Nothing named \(query)" : close.map(\.name).joined(separator: "\n")
    }

    private static func list(_ methods: [JSONValue], _ events: [JSONValue]) -> String {
        let width = (methods + events).map { $0["name"]?.string?.count ?? 0 }.max() ?? 0
        func row(_ v: JSONValue) -> String {
            let name = (v["name"]?.string ?? "").padding(toLength: width + 2, withPad: " ", startingAt: 0)
            return name + (v["description"]?.string.map(firstSentence) ?? "")
        }
        let open = methods.filter { $0["x-internal"]?.bool != true },
            own = methods.filter { $0["x-internal"]?.bool == true }
        return
            (["Methods"] + open.map(row) + ["", "Events"] + events.map(row) + ["", "Kelp's own, no promises"]
            + own.map(row)).joined(separator: "\n")
    }

    private static func firstSentence(_ s: String) -> String { s.components(separatedBy: ". ")[0] }

    private static func method(_ m: JSONValue) -> String {
        var lines = [(m["name"]?.string ?? "") + (m["x-internal"]?.bool == true ? "  Kelp's own, no promises" : "")]
        if let d = m["description"]?.string { lines.append(d) }
        lines += table(
            (m["params"]?.array ?? []).map {
                (
                    label: $0["name"]?.string ?? "", kind: kind($0["schema"]), required: $0["required"]?.bool == true,
                    about: $0["description"]?.string
                )
            })
        lines.append("→ " + kind(m["result"]?["schema"]))
        return lines.joined(separator: "\n")
    }

    private static func event(_ e: JSONValue) -> String {
        [(e["name"]?.string ?? ""), e["description"]?.string, "→ " + kind(e["params"])].compactMap { $0 }.joined(
            separator: "\n")
    }

    private static func type(_ name: String, _ s: JSONValue) -> String {
        if let cases = s["enum"]?.array {
            return "\(name): " + cases.map { $0.string ?? "\($0.int ?? 0)" }.joined(separator: ", ")
        }
        var lines = [name]
        if let d = s["description"]?.string { lines.append(d) }
        let required = s["required"]?.array ?? []
        guard case .object(let props)? = s["properties"] else {
            return (lines + ["→ " + kind(s)]).joined(separator: "\n")
        }
        lines += table(
            props.sorted { $0.key < $1.key }.map {
                (
                    label: $0.key, kind: kind($0.value), required: required.contains(.string($0.key)),
                    about: $0.value["description"]?.string
                )
            })
        return lines.joined(separator: "\n")
    }

    private static func table(_ rows: [(label: String, kind: String, required: Bool, about: String?)]) -> [String] {
        let name = rows.map(\.label.count).max() ?? 0, what = rows.map(\.kind.count).max() ?? 0
        return rows.map { r in
            let start =
                r.label.padding(toLength: name + 2, withPad: " ", startingAt: 0)
                + r.kind.padding(toLength: what + 2, withPad: " ", startingAt: 0)
            return "  "
                + (start + (r.required ? "required  " : "optional  ") + (r.about ?? "")).trimmingCharacters(
                    in: .whitespaces)
        }
    }

    /// A shape as it reads in a table: a type's name, `[X]` for a list, `{string: X}` for a map.
    private static func kind(_ s: JSONValue?) -> String {
        guard let s else { return "any" }
        if let ref = s["$ref"]?.string { return ref.components(separatedBy: "/").last ?? ref }
        if let items = s["items"] { return "[\(kind(items))]" }
        if let value = s["additionalProperties"] { return "{string: \(kind(value))}" }
        if s["contentEncoding"] != nil { return "base64" }
        if s["format"] != nil { return "date" }
        return s["type"]?.string ?? "any"
    }
}
