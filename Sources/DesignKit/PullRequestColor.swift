import AppKit

extension NSColor {
    /// A pull request's colour by state ("OPEN", "MERGED", "CLOSED"): open green, merged purple, draft and closed grey.
    /// Closed isn't red: nothing broke, and its symbol already tells it apart.
    public static func pullRequest(state: String, draft: Bool) -> NSColor {
        draft || state == "CLOSED" ? .secondaryLabelColor : state == "MERGED" ? .textPurple : .textGreen
    }
}
