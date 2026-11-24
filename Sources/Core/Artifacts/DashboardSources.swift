import Foundation

/// A dashboard's sources, as its agent declares them in canvas.json (Open Design's live artifacts): a name, the
/// read-only command that gets the data, and how its output becomes a figure. `"sources": {"issues": {"run": "gh issue
/// list --state open --json number", "map": "length"}}`; a figure `<b data-value data-from="issues">…</b>` shows it.
/// Kelp runs them again on Update without waking the agent.
public struct DashboardSource: Equatable, Sendable {
    public var name: String, run: String, map: String

    /// The sources `json` (canvas.json) declares, by name; none when it declares none or doesn't read.
    public static func read(_ json: String) -> [DashboardSource] {
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) } catch { return [] }
        guard let sources = (parsed as? [String: Any])?["sources"] as? [String: Any] else { return [] }
        return sources.keys.sorted().compactMap { name in
            guard let s = sources[name] as? [String: Any], let run = s["run"] as? String, !run.isEmpty else {
                return nil
            }
            return DashboardSource(name: name, run: run, map: s["map"] as? String ?? "text")
        }
    }

    /// What `output` shows as: `length` (how many items a JSON list has), `lines` (how many lines), `text` (the
    /// output itself), or a path into its JSON (`0.title`, `total`). nil when the map doesn't fit the output; throws
    /// when it should be JSON and isn't.
    public func value(_ output: String) throws -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch map {
        case "text": return text
        case "lines": return String(text.split(separator: "\n").count)
        default: break
        }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        if map == "length" { return (json as? [Any]).map { String($0.count) } }
        var at: Any? = json
        for key in map.split(separator: ".") {
            if let list = at as? [Any], let i = Int(key) {
                at = list.indices.contains(i) ? list[i] : nil
            } else {
                at = (at as? [String: Any])?[String(key)]
            }
        }
        switch at {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}

extension BoardEdit {
    /// `source` with every figure from source `name` (`data-from="name"`, its own text only) showing `value`, and its
    /// data-source saying `note` (where and when).
    public static func setFigures(_ source: String, from name: String, value: String, note: String) -> String {
        var out = source
        let marker = #"data-from=""# + name + #"""#
        for found in source.ranges(of: marker).reversed() {
            guard let open = source[..<found.lowerBound].lastIndex(of: "<"),
                let close = source[found.upperBound...].firstIndex(of: ">"),
                let end = source[close...].firstIndex(of: "<")
            else { continue }
            var tag = String(source[open...close]).replacing(/\sdata-source="[^"]*"/, with: "")
            tag.insert(
                contentsOf: #" data-source=""# + escape(note).replacingOccurrences(of: "\"", with: "&quot;") + "\"",
                at: tag.index(before: tag.endIndex))
            out.replaceSubrange(open..<end, with: tag + escape(value))
        }
        return out
    }
}
