import Core
import Foundation

/// What one click types into an agent back at its prompt: its row card's buttons and its banner's Continue. Compact
/// Now is the card's own, once the context fills.
struct QuickReply: Identifiable {
    let title: String, text: String
    var id: String { text }

    static let goOn = QuickReply(title: String(localized: "Continue"), text: "continue")
    static let all = [goOn, QuickReply(title: String(localized: "Looks Good, Go On"), text: "Looks good, go on.")]

    /// Done or failed, at its prompt: not one a limit stopped (Continue at its reset says when), nor one that asks
    /// (its menu would take the text).
    static func fits(_ s: Session) -> Bool {
        [.done, .error].contains(s.status) && s.limitHit == nil && !s.asksPermission
    }
}
