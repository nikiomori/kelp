import AppKit

/// Finding and replacing in a text: every search is a regular expression, plain text just escaped.
public struct FindOptions: Equatable, Sendable {
    public var matchCase = false, wholeWord = false, regex = false, preserveCase = false
    public init() {}
}

enum TextSearch {
    /// A word like `the` can match a lot of a 5 MB file: past this the bar says so, and doesn't keep them all.
    static let mostMatches = 10_000

    static func pattern(_ query: String, _ o: FindOptions) throws -> NSRegularExpression {
        var p = o.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if o.wholeWord { p = "\\b(?:" + p + ")\\b" }
        return try NSRegularExpression(pattern: p, options: o.matchCase ? [] : [.caseInsensitive])
    }

    static func matches(_ regex: NSRegularExpression, in s: NSString, within scope: NSRange? = nil) -> [NSTextCheckingResult] {
        var out: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: s as String, range: scope ?? NSRange(location: 0, length: s.length)) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            out.append(m)
            if out.count >= mostMatches { stop.pointee = true }
        }
        return out
    }

    /// What `m` becomes: `$1` and the like in a regex's template, `template` as it stands otherwise.
    static func replacement(_ m: NSTextCheckingResult, _ regex: NSRegularExpression, in s: NSString, template: String, _ o: FindOptions) -> String {
        let text = o.regex ? regex.replacementString(for: m, in: s as String, offset: 0, template: template) : template
        return o.preserveCase ? likeIt(text, s.substring(with: m.range)) : text
    }

    /// In the case `found` was: all capitals, or a capital first.
    static func likeIt(_ text: String, _ found: String) -> String {
        if found.count > 1, found == found.uppercased(), found != found.lowercased() { return text.uppercased() }
        if found.first?.isUppercase == true { return text.prefix(1).uppercased() + text.dropFirst() }
        return text
    }
}

/// One match of a replacement across files: what the line was and will be, and what goes where.
public struct ReplaceMatch: Equatable, Sendable {
    public let range: NSRange, text: String, line: Int, before: String, after: String
}

public enum ReplaceInText {
    /// Every match of `query` in `text` with what `template` makes of it. Throws on a pattern that isn't one.
    public static func plan(_ text: String, query: String, options: FindOptions, template: String) throws -> [ReplaceMatch] {
        let regex = try TextSearch.pattern(query, options), s = text as NSString
        var line = 1, scanned = 0
        return TextSearch.matches(regex, in: s).map { m in
            for i in scanned..<m.range.location where s.character(at: i) == 10 { line += 1 }
            scanned = m.range.location
            let new = TextSearch.replacement(m, regex, in: s, template: template, options)
            let whole = s.lineRange(for: m.range), head = NSRange(location: whole.location, length: m.range.location - whole.location)
            let tail = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(whole) - NSMaxRange(m.range))
            let before = s.substring(with: whole), after = s.substring(with: head) + new + s.substring(with: tail)
            return ReplaceMatch(range: m.range, text: new, line: line,
                                before: before.trimmingCharacters(in: .whitespacesAndNewlines), after: after.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// In one pass from the start: replacing in place moved the rest of the file once per match (10k matches in 3.8 MB, 5.5 s).
    public static func applying(_ matches: [ReplaceMatch], to text: String) -> String {
        let s = text as NSString, out = NSMutableString(capacity: s.length)
        var at = 0
        for m in matches.sorted(by: { $0.range.location < $1.range.location }) where m.range.location >= at {
            out.append(s.substring(with: NSRange(location: at, length: m.range.location - at)))
            out.append(m.text)
            at = NSMaxRange(m.range)
        }
        out.append(s.substring(from: at))
        return out as String
    }
}
