import AppKit

extension NSColor {
    /// A pull request's colour, as GitHub colours its state ("OPEN", "MERGED", "CLOSED"): open green, draft grey, merged
    /// purple, closed red.
    public static func pullRequest(state: String, draft: Bool) -> NSColor {
        draft ? .secondaryLabelColor : state == "MERGED" ? .textPurple : state == "CLOSED" ? .textRed : .textGreen
    }
}
