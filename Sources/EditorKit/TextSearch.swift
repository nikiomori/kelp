import AppKit

/// Finding and replacing in a text: every search is a regular expression, plain text just escaped.
public struct FindOptions: Equatable, Sendable {
    public var matchCase = false, wholeWord = false, regex = false, preserveCase = false
    public init() {}
}

enum TextSearch {
    /// A word like `the` can match a lot of a 5 MB file: past this the bar says so, and doesn't keep them all.
    static let mostMatches = 10_000

    static func pattern(_ query: String, _ options: FindOptions) throws -> NSRegularExpression {
        var source = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { source = "\\b(?:" + source + ")\\b" }
        return try NSRegularExpression(pattern: source, options: options.matchCase ? [] : [.caseInsensitive])
    }

    static func matches(_ regex: NSRegularExpression, in string: NSString, within scope: NSRange? = nil)
        -> [NSTextCheckingResult]
    {
        var out: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: string as String, range: scope ?? NSRange(location: 0, length: string.length)) {
            match, _, stop in
            guard let match, match.range.length > 0 else { return }
            out.append(match)
            if out.count >= mostMatches { stop.pointee = true }
        }
        return out
    }

    /// What `match` becomes: `$1` and the like in a regex's template, `template` as it stands otherwise.
    static func replacement(
        _ match: NSTextCheckingResult, _ regex: NSRegularExpression, in string: NSString, template: String,
        _ options: FindOptions
    ) -> String {
        let text =
            options.regex
            ? regex.replacementString(for: match, in: string as String, offset: 0, template: template) : template
        return options.preserveCase ? likeIt(text, string.substring(with: match.range)) : text
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
    public static func plan(_ text: String, query: String, options: FindOptions, template: String) throws
        -> [ReplaceMatch]
    {
        let regex = try TextSearch.pattern(query, options), string = text as NSString
        var line = 1, scanned = 0
        return TextSearch.matches(regex, in: string).map { match in
            for index in scanned..<match.range.location where string.character(at: index) == 10 { line += 1 }
            scanned = match.range.location
            let new = TextSearch.replacement(match, regex, in: string, template: template, options)
            let whole = string.lineRange(for: match.range),
                head = NSRange(location: whole.location, length: match.range.location - whole.location)
            let tail = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(whole) - NSMaxRange(match.range))
            let before = string.substring(with: whole),
                after = string.substring(with: head) + new + string.substring(with: tail)
            return ReplaceMatch(
                range: match.range, text: new, line: line,
                before: before.trimmingCharacters(in: .whitespacesAndNewlines),
                after: after.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// In one pass from the start: replacing in place moved the rest of the file once per match (10k matches in 3.8 MB, 5.5 s).
    public static func applying(_ matches: [ReplaceMatch], to text: String) -> String {
        let string = text as NSString, out = NSMutableString(capacity: string.length)
        var at = 0
        for match in matches.sorted(by: { $0.range.location < $1.range.location }) where match.range.location >= at {
            out.append(string.substring(with: NSRange(location: at, length: match.range.location - at)))
            out.append(match.text)
            at = NSMaxRange(match.range)
        }
        out.append(string.substring(from: at))
        return out as String
    }
}
