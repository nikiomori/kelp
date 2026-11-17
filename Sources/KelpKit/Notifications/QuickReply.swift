import Core
import Foundation

/// The replies that one click types into an agent that is back at its prompt: the buttons on its row's card, the Dock
/// strip's card, and its banner's Continue. Compact Now appears only on the row's card, once the context fills.
package struct QuickReply: Identifiable {
    package let title: String, text: String
    package var id: String { text }

    package static let goOn = QuickReply(title: String(localized: "Continue"), text: "continue")
    static let all = [
        goOn, QuickReply(title: String(localized: "Looks Good, Go On"), text: "Looks good, go on.")
    ]

    /// Done or failed, at its prompt: not one a limit stopped (Continue at its reset says when), nor one that asks
    /// (its menu would take the text).
    package static func fits(_ session: Session) -> Bool {
        [.done, .error].contains(session.status) && session.limitHit == nil && !session.asksPermission
    }
}
