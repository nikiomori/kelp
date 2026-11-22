import Foundation

/// The changes the user makes to a board by hand (Edit on the canvas): an element's text, typed over it, and its style,
/// from the properties panel. Each edit finds the element in the board's source by its `data-id` and changes only that
/// element, so the rest of the file stays as the agent wrote it. Each returns nil when the element can't be found for
/// sure, and then nothing is written.
public enum BoardEdit {
    /// Replaces the text of element `id`, which the page showed as `old`, with `new`. The element must hold only text
    /// (no child elements). Without a `data-id`, `old` must appear as an element's whole text exactly once in the file.
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

    /// Sets `property` to `value` in the inline style of element `id`, or removes it when `value` is nil. Only text
    /// that can't end the attribute or the declaration is accepted. The value comes from the panel's lists, and the
    /// property from its rows.
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

    /// Sets attribute `name` of element `id` to `value`, adding it when the element has none. Only a `data-` name or
    /// `src`, and a value that can't end the attribute, are taken (a motion page's times, an image replaced).
    public static func setAttribute(_ source: String, id: String, name: String, value: String) -> String? {
        guard name.hasPrefix("data-") || name == "src", name.allSatisfy({ $0.isLetter || $0 == "-" }),
            !value.contains(where: { "\"<>&".contains($0) }), let tag = openingTag(source, id: id)
        else { return nil }
        var opening = String(source[tag])
        let attribute = " \(name)=\"\(value)\""
        if let start = opening.range(of: " \(name)=\""),
            let end = opening[start.upperBound...].firstIndex(of: "\"")
        {
            opening.replaceSubrange(start.lowerBound...end, with: attribute)
        } else {
            opening.insert(contentsOf: attribute, at: opening.index(before: opening.endIndex))
        }
        var out = source
        out.replaceSubrange(tag, with: opening)
        return out
    }

    /// Returns the value of `property` in element `id`'s inline style, or nil when it sets none.
    public static func style(_ source: String, id: String, property: String) -> String? {
        guard let tag = openingTag(source, id: id), let style = source[tag].firstMatch(of: /\sstyle="([^"]*)"/)
        else { return nil }
        for part in style.output.1.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == property { return pair[1] }
        }
        return nil
    }

    /// Returns the range of the opening tag, from `<` to `>`, of the one element with `data-id="id"`. nil when there is
    /// no such element or more than one.
    static func openingTag(_ source: String, id: String) -> Range<String.Index>? {
        let attribute = "data-id=\"\(id)\""
        let found = source.ranges(of: attribute)
        guard found.count == 1, let at = found.first, let start = source[..<at.lowerBound].lastIndex(of: "<"),
            let end = source[at.upperBound...].firstIndex(of: ">")
        else { return nil }
        return start..<source.index(after: end)
    }

    /// Returns the whole element with `data-id="id"` (`elementRange`).
    public static func element(_ source: String, id: String) -> String? {
        elementRange(source, id: id).map { String(source[$0]) }
    }

    /// Takes element `id` out, with the line it stood on when it stood alone there.
    public static func remove(_ source: String, id: String) -> String? {
        guard var range = elementRange(source, id: id) else { return nil }
        let before = source[..<range.lowerBound].reversed().prefix(while: { $0 == " " || $0 == "\t" })
        if source[range.upperBound...].first == "\n",
            source[..<range.lowerBound].dropLast(before.count).last.map({ $0 == "\n" }) ?? true
        {
            range = source.index(range.lowerBound, offsetBy: -before.count)..<source.index(after: range.upperBound)
        }
        var out = source
        out.removeSubrange(range)
        return out
    }

    /// Puts a copy of element `id` right after it, on a line of its own when it stood on one. The copy's data-ids,
    /// its own and those inside it, get a number (`title-2`) that no element has yet. Returns the text and the copy's
    /// id.
    public static func duplicate(_ source: String, id: String) -> (text: String, id: String)? {
        guard let range = elementRange(source, id: id) else { return nil }
        let copy = String(source[range])
        let ids = copy.matches(of: /data-id="([^"]*)"/).map { String($0.output.1) }
        guard let n = (2...999).first(where: { n in ids.allSatisfy { !source.contains("data-id=\"\($0)-\(n)\"") } })
        else { return nil }
        let renamed = copy.replacing(/data-id="([^"]*)"/) { "data-id=\"\($0.output.1)-\(n)\"" }
        let indent = source[..<range.lowerBound].reversed().prefix(while: { $0 == " " || $0 == "\t" })
        let alone = source[..<range.lowerBound].dropLast(indent.count).last.map { $0 == "\n" } ?? true
        var out = source
        out.insert(contentsOf: (alone ? "\n" + String(indent.reversed()) : "") + renamed, at: range.upperBound)
        return (out, "\(id)-\(n)")
    }

    /// The range of the whole element with `data-id="id"`, from its opening tag to its closing one, counting the same
    /// tags opened inside it. nil when there is no such element, more than one, or it isn't closed.
    static func elementRange(_ source: String, id: String) -> Range<String.Index>? {
        guard let tag = openingTag(source, id: id) else { return nil }
        let name = source[tag].dropFirst().prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
        let voids: Set = ["img", "br", "hr", "input", "meta", "link", "source", "area", "col", "embed", "wbr"]
        guard !name.isEmpty else { return nil }
        if voids.contains(name) || source[tag].hasSuffix("/>") { return tag }
        var depth = 1, at = tag.upperBound
        while depth > 0, let lt = source[at...].firstIndex(of: "<") {
            let rest = source[source.index(after: lt)...]
            let closing = rest.hasPrefix("/")
            let word = (closing ? rest.dropFirst() : rest).prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
            if word.lowercased() == name { depth += closing ? -1 : 1 }
            at = source[lt...].firstIndex(of: ">").map(source.index(after:)) ?? source.endIndex
        }
        return depth == 0 ? tag.lowerBound..<at : nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{a0}").replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension DesignSystem {
    /// Returns the token names in each group of `tokens.json` (`color`, `size`, `space`, `radius`…), in order. They are
    /// the choices the properties panel offers, so a hand edit stays inside the design system.
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
