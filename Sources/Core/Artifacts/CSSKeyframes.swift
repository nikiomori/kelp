import Foundation

/// A page's `@keyframes` rule as a list of keyframes, to change one by hand: a motion page's keyframes moved, added,
/// taken out or given an easing. A keyframe is its place (0 to 100 percent) and its declarations in order; the easing
/// of the stretch after it is its `animation-timing-function`. Rules are found by name; `from` and `to` read as 0 and
/// 100, and a list of places (`0%, 50%`) gives each place the same declarations.
public enum CSSKeyframes {
    public struct Frame: Equatable, Sendable {
        public var at: Double
        public var declarations: [Declaration]
        public init(at: Double, declarations: [Declaration]) {
            self.at = at
            self.declarations = declarations
        }

        /// The value of `property`, or nil.
        public func value(_ property: String) -> String? { declarations.first { $0.property == property }?.value }

        /// Sets `property` to `value` (taking it away when nil), keeping the order.
        public mutating func set(_ property: String, _ value: String?) {
            if let i = declarations.firstIndex(where: { $0.property == property }) {
                if let value { declarations[i].value = value } else { declarations.remove(at: i) }
            } else if let value {
                declarations.append(Declaration(property: property, value: value))
            }
        }
    }

    public struct Declaration: Equatable, Sendable {
        public var property: String, value: String
        public init(property: String, value: String) {
            self.property = property
            self.value = value
        }
    }

    /// The keyframes of rule `name`, in order of place; nil when the page has no such rule or it doesn't read.
    public static func frames(_ source: String, name: String) -> [Frame]? {
        guard let rule = rule(source, name: name) else { return nil }
        var out: [Frame] = []
        // Comments go first: one before a keyframe would make its place unreadable, and the rule would be written
        // back without that keyframe.
        let body = String(source[rule.body]).replacing(/\/\*[\s\S]*?\*\//, with: "")
        var rest = body[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let names = rest[..<open].split(separator: ",")
            let places = names.compactMap { place(String($0)) }
            guard places.count == names.count else { return nil }   // a place this doesn't read: not written over
            let declarations = rest[rest.index(after: open)..<close].split(separator: ";").compactMap {
                part -> Declaration? in
                let pair = part.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return pair.count == 2 && !pair[0].isEmpty ? Declaration(property: pair[0], value: pair[1]) : nil
            }
            out += places.map { Frame(at: $0, declarations: declarations) }
            rest = rest[rest.index(after: close)...]
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The page with rule `name`'s keyframes replaced by `frames`; nil when it has no such rule.
    public static func write(_ source: String, name: String, frames: [Frame]) -> String? {
        guard let rule = rule(source, name: name) else { return nil }
        let lines = frames.sorted { $0.at < $1.at }.map { frame in
            let body = frame.declarations.map { "\($0.property): \($0.value)" }.joined(separator: "; ")
            return "  \(percent(frame.at)) { \(body) }"
        }
        var out = source
        out.replaceSubrange(rule.body, with: "\n" + lines.joined(separator: "\n") + "\n")
        return out
    }

    /// The page with a new rule `name` of `frames`, in its first `<style>` (or a new one).
    public static func add(_ source: String, name: String, frames: [Frame]) -> String? {
        guard rule(source, name: name) == nil, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        let empty = "@keyframes \(name) {}"
        var out = source
        if let end = source.range(of: "</style>", options: .caseInsensitive) {
            out.insert(contentsOf: empty + "\n", at: end.lowerBound)
        } else if let head = source.range(of: "</head>", options: .caseInsensitive) {
            out.insert(contentsOf: "<style>\(empty)</style>\n", at: head.lowerBound)
        } else {
            out = "<style>\(empty)</style>\n" + source
        }
        return write(out, name: name, frames: frames)
    }

    /// `45` as `45%`, `12.5` as `12.5%`.
    public static func percent(_ at: Double) -> String { String(format: "%g%%", (at * 10).rounded() / 10) }

    private static func place(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "from" { return 0 }
        if t == "to" { return 100 }
        guard t.hasSuffix("%"), let n = Double(t.dropLast()) else { return nil }
        return n
    }

    /// Where rule `name` is, and its body between its braces.
    private static func rule(_ source: String, name: String) -> (whole: Range<String.Index>, body: Range<String.Index>)?
    {
        var from = source.startIndex
        var found: Range<String.Index>?
        while found == nil, let word = source.range(of: "keyframes", range: from..<source.endIndex) {
            from = word.upperBound
            guard source[..<word.lowerBound].hasSuffix("@") || source[..<word.lowerBound].hasSuffix("@-webkit-") else {
                continue
            }
            let rest = source[word.upperBound...].drop(while: \.isWhitespace)
            guard rest.hasPrefix(name) else { continue }
            let after = rest.dropFirst(name.count).drop(while: \.isWhitespace)
            if after.first == "{" { found = word.lowerBound..<source.index(after: after.startIndex) }
        }
        guard let start = found else { return nil }
        var depth = 1, at = start.upperBound
        while depth > 0, at < source.endIndex {
            if source[at] == "{" { depth += 1 } else if source[at] == "}" { depth -= 1 }
            if depth > 0 { at = source.index(after: at) }
        }
        guard depth == 0 else { return nil }
        return (start.lowerBound..<source.index(after: at), start.upperBound..<at)
    }
}
