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
        var out = source
        out.replaceSubrange(tag, with: restyle(String(source[tag]), property: property, value: value))
        return out
    }

    /// Sets `property` on every element with class `className` (`card`, no dot), returning the page and how many it
    /// changed; nil when the property or value can't be written.
    public static func setStyle(_ source: String, className: String, property: String, value: String?) -> (String, Int)?
    {
        guard property.allSatisfy({ $0.isLetter || $0 == "-" }), !className.isEmpty,
            className.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
            value.map({ !$0.contains(where: { ";\"<>{}".contains($0) }) }) ?? true
        else { return nil }
        var out = source, count = 0
        for found in source.matches(of: /<[a-zA-Z][^<>]*\sclass="([^"]*)"[^<>]*>/).reversed()
        where found.output.1.split(separator: " ").contains(Substring(className)) {
            out.replaceSubrange(found.range, with: restyle(String(found.output.0), property: property, value: value))
            count += 1
        }
        return (out, count)
    }

    /// Opening tag `opening` with `property` set to `value` in its style (taken away when nil).
    private static func restyle(_ opening: String, property: String, value: String?) -> String {
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
        return tagText
    }

    /// Sets attribute `name` of element `id` (the page's `<body>` when nil) to `value`, adding it when the element has
    /// none, or takes it away when `value` is nil. Only a `data-` name or `src`, and a value that can't end the
    /// attribute, are taken (a motion page's times and size, an element hidden, an image replaced); a link's and a
    /// picture's words (`href`, `target`, `alt`) take any text, written escaped.
    public static func setAttribute(_ source: String, id: String?, name: String, value: String?) -> String? {
        let words = ["href", "target", "alt"].contains(name)
        guard name.hasPrefix("data-") || name == "src" || words, name.allSatisfy({ $0.isLetter || $0 == "-" }),
            words || !(value ?? "").contains(where: { "\"<>&".contains($0) }),
            let tag = id.map({ openingTag(source, id: $0) }) ?? bodyTag(source)
        else { return nil }
        var opening = String(source[tag])
        let written = words ? value.map { escape($0).replacingOccurrences(of: "\"", with: "&quot;") } : value
        let attribute = written.map { " \(name)=\"\($0)\"" } ?? ""
        if let start = opening.range(of: " \(name)=\""),
            let end = opening[start.upperBound...].firstIndex(of: "\"")
        {
            opening.replaceSubrange(start.lowerBound...end, with: attribute)
        } else if !attribute.isEmpty {
            opening.insert(contentsOf: attribute, at: opening.index(before: opening.endIndex))
        }
        var out = source
        out.replaceSubrange(tag, with: opening)
        return out
    }

    /// Returns attribute `name` of element `id` as written in its tag, unescaped, or nil when it has none.
    public static func attribute(_ source: String, id: String, name: String) -> String? {
        guard let tag = openingTag(source, id: id), let at = source[tag].range(of: " \(name)=\""),
            let end = source[at.upperBound..<tag.upperBound].firstIndex(of: "\"")
        else { return nil }
        return unescape(String(source[at.upperBound..<end]))
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

    /// Gives the `index`th `<tag>` of the page's body (or of a board's fragment) a data-id made from the tag, the first
    /// of `h2-1`, `h2-2`… no element has. Returns the text and the id, or nil when there is no such tag.
    public static func giveID(_ source: String, tag: String, index: Int, named: String? = nil) -> (
        text: String, id: String
    )? {
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let start = bodyTag(source)?.upperBound ?? source.startIndex
        // What the page's DOM doesn't count among the body's elements: comments, a template's insides, and the text
        // of scripts and styles.
        let unseen = source.ranges(
            of: /<!--[\s\S]*?-->|<template\b[\s\S]*?<\/template>|<script\b[\s\S]*?<\/script>|<style\b[\s\S]*?<\/style>/
                .ignoresCase())
        var opens: [Range<String.Index>] = [], from = start
        while let found = source.range(of: "<" + tag, options: .caseInsensitive, range: from..<source.endIndex) {
            if source[found.upperBound...].first.map({ $0.isWhitespace || $0 == ">" || $0 == "/" }) ?? false,
                !unseen.contains(where: { $0.contains(found.lowerBound) && $0.lowerBound != found.lowerBound })
            {
                opens.append(found)
            }
            from = found.upperBound
        }
        guard opens.indices.contains(index) else { return nil }
        // One that has a data-id already keeps it.
        if let end = source[opens[index].upperBound...].firstIndex(of: ">"),
            let had = source[opens[index].upperBound..<end].firstMatch(of: /data-id="([^"]*)"/)
        {
            return (source, String(had.1))
        }
        let id =
            named.flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? $0 : nil }
            .flatMap { source.contains("data-id=\"\($0)\"") ? nil : $0 } ?? freeID(source, tag.lowercased())
        var out = source
        out.insert(contentsOf: " data-id=\"\(id)\"", at: source.index(opens[index].lowerBound, offsetBy: tag.count + 1))
        return (out, id)
    }

    /// Puts `html` at the end of the page's body, on a line of its own, or at the end when it has no `</body>`.
    public static func appendToBody(_ source: String, _ html: String) -> String {
        var out = source
        let end = source.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? source.endIndex
        out.insert(contentsOf: html + "\n", at: end)
        return out
    }

    /// The first `prefix-1`, `prefix-2`… that no element has as its data-id.
    public static func freeID(_ source: String, _ prefix: String) -> String {
        (1...).lazy.map { "\(prefix)-\($0)" }.first { !source.contains("data-id=\"\($0)\"") } ?? prefix
    }

    /// The range of the page's one `<body …>` tag.
    static func bodyTag(_ source: String) -> Range<String.Index>? {
        let found = source.ranges(of: /<body[\s>]/.ignoresCase())
        guard found.count == 1, let at = found.first, let end = source[at.lowerBound...].firstIndex(of: ">")
        else { return nil }
        return at.lowerBound..<source.index(after: end)
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

    /// Puts `html` inside element `id`, in place of what it holds: words styled by hand. Only spans, b, i, u, strong,
    /// em and br are taken, with a style at most; anything else (a script, a handler) and nil.
    public static func setInner(_ source: String, id: String, html: String) -> String? {
        let tags = html.matches(of: /<\/?([a-zA-Z]+)([^>]*)>/)
        let fine = tags.allSatisfy { tag in
            ["span", "b", "i", "u", "strong", "em", "br"].contains(tag.output.1.lowercased())
                && (tag.output.2.trimmingCharacters(in: .whitespaces).isEmpty
                    || tag.output.2.wholeMatch(of: /\s+style="[^"<>]*"\s*/) != nil)
        }
        guard fine, let whole = elementRange(source, id: id), let open = openingTag(source, id: id),
            let close = source[whole].lastIndex(of: "<"), close >= open.upperBound
        else { return nil }
        var out = source
        out.replaceSubrange(open.upperBound..<close, with: html)
        return out
    }

    /// Brings font file `file` (beside the page) into the page as family `family`: an @font-face in its first
    /// `<style>`, or in a new one. A name or a path with a quote or an angle bracket is refused.
    public static func addFontFace(_ source: String, family: String, file: String) -> String? {
        guard !(family + file).contains(where: { "'\"<>".contains($0) }) else { return nil }
        let face = "@font-face { font-family: '\(family)'; src: url('\(file)'); font-display: swap; }"
        var out = source
        if let end = source.range(of: "</style>", options: .caseInsensitive) {
            out.insert(contentsOf: face + "\n", at: end.lowerBound)
        } else if let head = source.range(of: "</head>", options: .caseInsensitive) {
            out.insert(contentsOf: "<style>\(face)</style>\n", at: head.lowerBound)
        } else {
            out = "<style>\(face)</style>\n" + source
        }
        return out
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
        guard let (renamed, newID) = renamed(String(source[range]), in: source) else { return nil }
        let indent = source[..<range.lowerBound].reversed().prefix(while: { $0 == " " || $0 == "\t" })
        let alone = source[..<range.lowerBound].dropLast(indent.count).last.map { $0 == "\n" } ?? true
        var out = source
        out.insert(contentsOf: (alone ? "\n" + String(indent.reversed()) : "") + renamed, at: range.upperBound)
        return (out, newID)
    }

    /// `html` (an element copied) with its data-ids, its own and those inside it, numbered (`title-2`) so none is one
    /// `source` has yet. Returns it and its own new id.
    public static func renamed(_ html: String, in source: String) -> (html: String, id: String)? {
        let ids = html.matches(of: /data-id="([^"]*)"/).map { String($0.output.1) }
        guard let first = ids.first,
            let n = (2...999).first(where: { n in ids.allSatisfy { !source.contains("data-id=\"\($0)-\(n)\"") } })
        else { return nil }
        return (html.replacing(/data-id="([^"]*)"/) { "data-id=\"\($0.output.1)-\(n)\"" }, "\(first)-\(n)")
    }

    /// The range of the whole element with `data-id="id"`, from its opening tag to its closing one, counting the same
    /// tags opened inside it. nil when there is no such element, more than one, or it isn't closed.
    static func elementRange(_ source: String, id: String) -> Range<String.Index>? {
        openingTag(source, id: id).flatMap { elementRange(source, tag: $0) }
    }

    /// The range of the whole element whose opening tag is `tag`, to its closing one; nil when it isn't closed.
    static func elementRange(_ source: String, tag: Range<String.Index>) -> Range<String.Index>? {
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
