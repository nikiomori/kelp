import Foundation

/// What the user changes on a board by hand (Edit on the canvas): an element's text, typed over it, and its style, from
/// the properties panel. Each finds the element in the board's source by its `data-id`, and changes only that: the
/// rest of the file stays as the agent wrote it. nil when the element can't be found for sure (then nothing is
/// written).
public enum BoardEdit {
    /// `id`'s text, `old` as the page showed it, made `new`. The element holds only text (no child elements); without a
    /// `data-id`, `old` must appear as an element's whole text exactly once in the file.
    public static func setText(_ source: String, id: String?, old: String, new: String) -> String? {
        let typed = escape(new)
        if let id {
            guard let tag = openingTag(source, id: id), let close = source[tag.upperBound...].firstIndex(of: "<"),
                unescape(String(source[tag.upperBound..<close])).trimmingCharacters(in: .whitespacesAndNewlines)
                    == old.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            var out = source
            out.replaceSubrange(tag.upperBound..<close, with: typed)
            return out
        }
        let whole = source.ranges(of: ">" + escape(old) + "<")
        guard whole.count == 1, let range = whole.first else { return nil }
        var out = source
        out.replaceSubrange(source.index(after: range.lowerBound)..<source.index(before: range.upperBound), with: typed)
        return out
    }

    /// `id`'s inline style with `property` set to `value`, or taken away for nil. Only what can't end the attribute or
    /// the declaration passes: the value comes from the panel's lists, the property from its rows.
    public static func setStyle(_ source: String, id: String, property: String, value: String?) -> String? {
        guard property.allSatisfy({ $0.isLetter || $0 == "-" }),
            value.map({ !$0.contains(where: { ";\"<>{}".contains($0) }) }) ?? true,
            let tag = openingTag(source, id: id)
        else { return nil }
        let opening = String(source[tag])
        var declarations: [(String, String)] = []
        if let style = opening.firstMatch(of: /\sstyle="([^"]*)"/) {
            declarations = style.output.1.split(separator: ";").compactMap { part in
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pair.count == 2 && !pair[0].isEmpty ? (pair[0], pair[1]) : nil
            }
        }
        declarations.removeAll { $0.0 == property }
        if let value { declarations.append((property, value)) }
        let style = declarations.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
        let attribute = style.isEmpty ? "" : " style=\"\(style)\""
        var tagText = opening.replacing(/\sstyle="[^"]*"/, with: "")
        tagText.insert(contentsOf: attribute, at: tagText.index(before: tagText.endIndex))
        var out = source
        out.replaceSubrange(tag, with: tagText)
        return out
    }

    /// The opening tag of the one element with `data-id="id"`, from `<` to `>`; nil for none or more than one.
    static func openingTag(_ source: String, id: String) -> Range<String.Index>? {
        let attribute = "data-id=\"\(id)\""
        let found = source.ranges(of: attribute)
        guard found.count == 1, let at = found.first, let start = source[..<at.lowerBound].lastIndex(of: "<"),
            let end = source[at.upperBound...].firstIndex(of: ">")
        else { return nil }
        return start..<source.index(after: end)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{a0}").replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension DesignSystem {
    /// The token names in each group of `tokens.json` (`color`, `size`, `space`, `radius`…), in order: the choices the
    /// properties panel offers, so a hand edit stays inside the system.
    public static func names(tokens json: String) -> [String: [String]] {
        let object: JSONValue
        do { object = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) } catch { return [:] }
        guard case .object(let groups) = object else { return [:] }
        var out: [String: [String]] = [:]
        for (group, value) in groups {
            guard case .object(let tokens) = value, isName(group) else { continue }
            out[group] = tokens.keys.filter(isName).sorted()
        }
        return out
    }
}
