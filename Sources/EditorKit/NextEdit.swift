import Foundation

/// The next edit, Cursor Tab's way: after an edit, a model (Sweep Next-Edit) reads the cursor's lines as they were
/// before it and as they are now, and writes those lines as it guesses they'll be next. What it changed is offered in
/// place, struck through and written in green: ⇥ goes there, ⇥ again takes it.
public enum NextEdit {
    /// Lines either side of the cursor the model writes again: on Kelp's history ±8 was right about as often as ±15,
    /// three times sooner.
    public static let half = 8
    /// The most lines an edit offered may take away or put in; more is the model losing its place, not a pattern.
    static let most = 12
    /// The most lines of an edit made that the model is shown, each side: more is a paste.
    static let shownLines = 30

    /// An edit made: its lines before and after.
    public struct Change: Equatable, Sendable {
        public var old: String, new: String
    }

    /// What the model is asked.
    public struct Ask: Equatable, Sendable {
        /// Edits made before the latest, oldest first, and the latest.
        public var earlier: [Change], latest: Change
        /// The cursor's lines before the latest edit, and now.
        public var original: String, current: String
        /// The window's first line in the text now.
        public var firstLine: Int
    }

    /// An edit offered, in the text now: `lines` become `new`.
    public struct Proposal: Equatable {
        public var lines: Range<Int>
        public var old: [String], new: [String]
        /// The lines the cursor takes it from with one ⇥: its own, or the two it goes between when it only adds.
        var reach: Range<Int> { lines.isEmpty ? lines.lowerBound - 1..<lines.lowerBound + 1 : lines }
    }

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// How many lines `a` and `b` share at the start and at the end (never overlapping); nil when they're the same.
    static func shared(
        _ a: [String], _ b: [String], same: (String, String) -> Bool = (==)
    ) -> (start: Int, end: Int)? {
        var start = 0
        while start < a.count, start < b.count, same(a[start], b[start]) { start += 1 }
        if start == a.count, start == b.count { return nil }
        var end = 0
        while end < a.count - start, end < b.count - start, same(a[a.count - 1 - end], b[b.count - 1 - end]) {
            end += 1
        }
        return (start, end)
    }

    /// The edit that made `now` out of `base`, nil when there's none or it's a paste.
    static func change(from base: [String], to now: [String]) -> Change? {
        guard let (start, end) = shared(base, now) else { return nil }
        let old = base[start..<base.count - end], new = now[start..<now.count - end]
        guard old.count <= shownLines, new.count <= shownLines else { return nil }
        return Change(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
    }

    /// What to ask about the cursor on `line`, after the edits that made `now` out of `base`.
    static func ask(base: String, now: String, line: Int, earlier: [Change]) -> Ask? {
        let before = lines(base), after = lines(now)
        guard let latest = change(from: before, to: after), let (start, end) = shared(before, after) else { return nil }
        let low = max(0, line - half), high = min(after.count, line + half + 1)
        // The window's ends as they were: a line inside the edit stands for the edit's own end.
        let moved = after.count - before.count, editEnd = after.count - end
        let from = low <= start ? low : low >= editEnd ? low - moved : start
        let to = high <= start ? high : high >= editEnd ? high - moved : before.count - end
        return Ask(
            earlier: earlier, latest: latest, original: before[from..<max(from, to)].joined(separator: "\n"),
            current: after[low..<high].joined(separator: "\n"), firstLine: low)
    }

    /// The edit the model's `answer` (the window written again) offers; nil when it changes nothing, or more than an
    /// edit, or stopped short.
    static func proposal(_ answer: String, for ask: Ask) -> Proposal? {
        let now = lines(ask.current)
        var got = lines(answer)
        while got.count > now.count, got.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { got.removeLast() }
        let trimmed = { (s: String) in s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        guard let (start, end) = shared(now, got, same: { trimmed($0) == trimmed($1) }) else { return nil }
        let old = Array(now[start..<now.count - end]), new = Array(got[start..<got.count - end])
        // Nothing kept at the end and fewer lines: the answer ran out, it didn't delete the window's last lines.
        guard old.count <= most, new.count <= most, end > 0 || new.count >= old.count,
            !(old.isEmpty && ask.firstLine + start == 0)   // added above the first line: nowhere to show it
        else { return nil }
        let first = ask.firstLine + start
        return Proposal(lines: first..<first + old.count, old: old, new: new)
    }

    /// For a line written another way: what goes (in the old line's UTF-16 offsets) and what comes in its place.
    static func inline(_ old: String, _ new: String) -> (gone: NSRange, put: String) {
        let a = old as NSString, b = new as NSString
        var start = 0
        while start < a.length, start < b.length, a.character(at: start) == b.character(at: start) { start += 1 }
        var end = 0
        while end < a.length - start, end < b.length - start,
            a.character(at: a.length - 1 - end) == b.character(at: b.length - 1 - end)
        {
            end += 1
        }
        return (
            NSRange(location: start, length: a.length - start - end),
            b.substring(with: NSRange(location: start, length: b.length - start - end))
        )
    }

    /// What taking `proposal` replaces in `string` (whole lines, with their line breaks), and with what.
    static func replacement(_ proposal: Proposal, in string: NSString) -> (range: NSRange, text: String) {
        var start = 0, line = 0
        while line < proposal.lines.lowerBound, start < string.length {
            start = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        var end = start
        for _ in proposal.lines where end < string.length {
            end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0)))
        }
        let breaks = end > start && string.character(at: end - 1) == 10
        let text =
            proposal.new.isEmpty
            ? "" : proposal.new.joined(separator: "\n") + (proposal.old.isEmpty || breaks ? "\n" : "")
        return (NSRange(location: start, length: end - start), text)
    }
}
