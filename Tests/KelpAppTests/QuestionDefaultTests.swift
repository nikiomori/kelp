import AppKit
import Testing

@testable import DesignKit

/// A question as `runSheet` gets it: from `NSAlert(question:)`, or built by hand with one button marked destructive.
private enum Asked: Sendable {
    case question(action: String, cancel: String?, destructive: Bool)
    case byHand([String], destructive: Int)

    @MainActor var alert: NSAlert {
        switch self {
        case .question(let action, let cancel, let destructive):
            return NSAlert(question: "?", action: action, cancel: cancel, destructive: destructive)
        case .byHand(let titles, let destructive):
            let alert = NSAlert()
            for title in titles { alert.addButton(withTitle: title) }
            alert.buttons[destructive].hasDestructiveAction = true
            return alert
        }
    }
}

/// What Return and Esc pick once `runSheet` has a question: never a destructive button.
@MainActor
@Test(arguments: [
    // the builder: a destructive action takes a click; any other keeps Return; the cancel, whatever its title, takes Esc
    (Asked.question(action: "Delete", cancel: nil, destructive: true), ["", "\u{1b}"]),
    (.question(action: "Run Setup", cancel: "Skip", destructive: true), ["", "\u{1b}"]),
    (.question(action: "Rename", cancel: nil, destructive: false), ["\r", "\u{1b}"]),
    // by hand: the destructive button loses Return wherever it stands, and a safe first button keeps it
    (.byHand(["Delete and Lose Changes", "Cancel"], destructive: 0), ["", "\u{1b}"]),
    (.byHand(["Archive", "Delete and Lose Changes", "Cancel"], destructive: 1), ["\r", "", "\u{1b}"])
])
private func aDestructiveQuestionHasNoDefault(asked: Asked, keys: [String]) {
    let alert = asked.alert
    alert.noDestructiveDefault()
    #expect(alert.buttons.map(\.keyEquivalent) == keys)
}
