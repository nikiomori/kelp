import Foundation

/// A merge conflict as git writes it into a file: `<<<<<<<`, the current side, `|||||||` and the base (diff3's, if
/// any), `=======`, the incoming side, `>>>>>>>`. Ranges are UTF-16, as the editor's.
struct MergeConflict: Equatable {
    /// From the start of the `<<<<<<<` line to the end of the `>>>>>>>` one, its line break included.
    let whole: NSRange
    let current: NSRange, incoming: NSRange

    enum Keep { case current, incoming, both }

    /// Every conflict in `text`, in order. A marker counts only at a line's start, followed by a space or the line's
    /// end, and only in its place: a lone `=======` (a Markdown heading's underline) or an unfinished block is no conflict.
    static func all(in text: String) -> [MergeConflict] {
        let s = text as NSString
        guard s.range(of: "<<<<<<<").location != NSNotFound else { return [] }
        var found: [MergeConflict] = []
        var start: Int?, currentStart = 0, currentEnd: Int?, incomingStart: Int?
        var at = 0
        while at < s.length {
            let line = s.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(line)
            guard let marker = marker(s, line) else { continue }
            switch marker {
            case "<": (start, currentStart, currentEnd, incomingStart) = (line.location, at, nil, nil)
            case "|" where start != nil && currentEnd == nil: currentEnd = line.location
            case "=" where start != nil && incomingStart == nil:
                currentEnd = currentEnd ?? line.location
                incomingStart = at
            case ">":
                if let start, let currentEnd, let incomingStart {
                    found.append(
                        MergeConflict(
                            whole: NSRange(location: start, length: at - start),
                            current: NSRange(location: currentStart, length: currentEnd - currentStart),
                            incoming: NSRange(location: incomingStart, length: line.location - incomingStart)))
                }
                start = nil
            default: break
            }
        }
        return found
    }

    /// What replaces the whole block when `keep` is picked.
    func resolved(in text: String, keeping keep: Keep) -> String {
        let s = text as NSString
        let mine = s.substring(with: current), theirs = s.substring(with: incoming)
        switch keep {
        case .current: return mine
        case .incoming: return theirs
        case .both: return mine + theirs
        }
    }

    /// The text with this conflict resolved.
    func resolving(_ text: String, keeping keep: Keep) -> String {
        (text as NSString).replacingCharacters(in: whole, with: resolved(in: text, keeping: keep))
    }

    /// "<", "|", "=" or ">" when the line is that marker.
    private static func marker(_ s: NSString, _ line: NSRange) -> Character? {
        guard line.length >= 7 else { return nil }
        let head = s.substring(with: NSRange(location: line.location, length: 7))
        guard let first = head.first, ["<", "|", "=", ">"].contains(first), head.allSatisfy({ $0 == first }) else {
            return nil
        }
        let rest = s.substring(with: NSRange(location: line.location + 7, length: line.length - 7))
        if first == "=" { return rest.trimmingCharacters(in: .newlines).isEmpty ? first : nil }
        return rest.isEmpty || rest.first == " " || rest.first?.isNewline == true ? first : nil
    }
}
