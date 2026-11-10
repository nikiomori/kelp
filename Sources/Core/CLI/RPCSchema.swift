import Foundation

/// `kelp schema`: Resources/rpc.json, which Tests/DaemonTests/RPCSchemaTests.swift keeps in step with the types, as text.
public enum RPCSchema {
    /// All the methods, or what `query` names: a method, an event or a type, exactly or as the only name holding it.
    public static func text(_ doc: JSONValue, _ query: String? = nil) -> String {
        let methods = doc["methods"]?.array ?? [], events = doc["x-events"]?.array ?? []
        var types: [String: JSONValue] = [:]
        if case .object(let schemas)? = doc["components"]?["schemas"] { types = schemas }
        guard let query, !query.isEmpty else { return list(methods, events) }
        let lowered = query.lowercased()
        func name(_ entry: JSONValue) -> String { entry["name"]?.string ?? "" }
        let shown: [(name: String, text: () -> String)] =
            methods.map { m in (name(m), { method(m) }) } + events.map { e in (name(e), { event(e) }) }
            + types.keys.sorted().map { key in (key, { type(key, types[key] ?? .null) }) }
        if let hit = shown.first(where: { $0.name.lowercased() == lowered }) { return hit.text() }
        let close = shown.filter { $0.name.lowercased().contains(lowered) }
        if close.count == 1 { return close[0].text() }
        return close.isEmpty ? "Nothing named \(query)" : close.map(\.name).joined(separator: "\n")
    }

    private static func list(_ methods: [JSONValue], _ events: [JSONValue]) -> String {
        let width = (methods + events).map { $0["name"]?.string?.count ?? 0 }.max() ?? 0
        func row(_ entry: JSONValue) -> String {
            let name = (entry["name"]?.string ?? "").padding(toLength: width + 2, withPad: " ", startingAt: 0)
            return name + (entry["description"]?.string.map(firstSentence) ?? "")
        }
        let open = methods.filter { $0["x-internal"]?.bool != true },
            own = methods.filter { $0["x-internal"]?.bool == true }
        return
            (["Methods"] + open.map(row) + ["", "Events"] + events.map(row) + ["", "Kelp's own, no promises"]
            + own.map(row)).joined(separator: "\n")
    }

    private static func firstSentence(_ text: String) -> String { text.components(separatedBy: ". ")[0] }

    private static func method(_ entry: JSONValue) -> String {
        var lines = [
            (entry["name"]?.string ?? "") + (entry["x-internal"]?.bool == true ? "  Kelp's own, no promises" : "")
        ]
        if let about = entry["description"]?.string { lines.append(about) }
        lines += table(
            (entry["params"]?.array ?? []).map {
                (
                    label: $0["name"]?.string ?? "", kind: kind($0["schema"]), required: $0["required"]?.bool == true,
                    about: $0["description"]?.string
                )
            })
        lines.append("→ " + kind(entry["result"]?["schema"]))
        return lines.joined(separator: "\n")
    }

    private static func event(_ entry: JSONValue) -> String {
        [(entry["name"]?.string ?? ""), entry["description"]?.string, "→ " + kind(entry["params"])].compactMap { $0 }
            .joined(
                separator: "\n")
    }

    private static func type(_ name: String, _ schema: JSONValue) -> String {
        if let cases = schema["enum"]?.array {
            return "\(name): " + cases.map { $0.string ?? "\($0.int ?? 0)" }.joined(separator: ", ")
        }
        var lines = [name]
        if let about = schema["description"]?.string { lines.append(about) }
        let required = schema["required"]?.array ?? []
        guard case .object(let props)? = schema["properties"] else {
            return (lines + ["→ " + kind(schema)]).joined(separator: "\n")
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
        return rows.map { row in
            let start =
                row.label.padding(toLength: name + 2, withPad: " ", startingAt: 0)
                + row.kind.padding(toLength: what + 2, withPad: " ", startingAt: 0)
            return "  "
                + (start + (row.required ? "required  " : "optional  ") + (row.about ?? "")).trimmingCharacters(
                    in: .whitespaces)
        }
    }

    /// A shape as it reads in a table: a type's name, `[X]` for a list, `{string: X}` for a map.
    private static func kind(_ schema: JSONValue?) -> String {
        guard let schema else { return "any" }
        if let ref = schema["$ref"]?.string { return ref.components(separatedBy: "/").last ?? ref }
        if let items = schema["items"] { return "[\(kind(items))]" }
        if let value = schema["additionalProperties"] { return "{string: \(kind(value))}" }
        if schema["contentEncoding"] != nil { return "base64" }
        if schema["format"] != nil { return "date" }
        return schema["type"]?.string ?? "any"
    }
}
