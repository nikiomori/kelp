import Core
import Foundation

/// The replies that one click types into an agent that is back at its prompt. They are the buttons on the card of the
/// agent's row and on the Dock strip's card, and the Continue on its banner. Compact Now appears only on the row's
/// card, once the context fills.
package struct QuickReply: Identifiable {
    package let title: String, text: String
    package var id: String { text }

    package static let goOn = QuickReply(title: String(localized: "Continue"), text: "continue")
    static let all = [
        goOn, QuickReply(title: String(localized: "Looks Good, Go On"), text: "Looks good, go on.")
    ]

    /// Whether quick replies fit the session: it is done or failed and back at its prompt. They don't fit a session
    /// that a limit stopped (Continue at its reset says when), or one that asks a permission (its menu would take the
    /// text).
    package static func fits(_ session: Session) -> Bool {
        [.done, .error].contains(session.status) && session.limitHit == nil && !session.asksPermission
    }
}
