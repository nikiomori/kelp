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
