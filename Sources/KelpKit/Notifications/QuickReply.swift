import Core
import Foundation

/// What one click types into an agent back at its prompt: its row card's buttons, the Dock strip's card and its banner's
/// Continue. Compact Now is the row card's own, once the context fills.
package struct QuickReply: Identifiable {
    package let title: String, text: String
    package var id: String { text }

    package static let goOn = QuickReply(title: String(localized: "Continue"), text: "continue")
    static let all = [
        goOn, QuickReply(title: String(localized: "Looks Good, Go On"), text: "Looks good, go on.")
    ]

    /// Done or failed, at its prompt: not one a limit stopped (Continue at its reset says when), nor one that asks
    /// (its menu would take the text).
    package static func fits(_ s: Session) -> Bool {
        [.done, .error].contains(s.status) && s.limitHit == nil && !s.asksPermission
    }
}
