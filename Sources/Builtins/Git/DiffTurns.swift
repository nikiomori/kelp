import AppKit
import Core
import KelpKit

/// The agent's turns, newest first, beside the "Agent's Last Turn" source: each one's start is kept by the daemon
/// (`SessionTurns`), so any of them can be read again, named by the prompt that started it.
extension DiffViewController {
    /// The turn picked, nil for the last one.
    var chosenTurn: String? {
        guard turnPop.indexOfSelectedItem > 0 else { return nil }
        return turnPop.selectedItem?.representedObject as? String
    }

    /// The picker's turns read again, the one picked kept; hidden with no history (a remote project, none yet).
    func readTurns(_ session: String?) async {
        var marks: [SessionTurns.Mark] = []
        if let session { marks = await app.quiet(SessionTurns(id: session)) ?? [] }
        let picked = chosenTurn
        turnPop.removeAllItems()
        for (i, m) in marks.enumerated() {
            let when = m.at.formatted(date: .omitted, time: .shortened)
            let title = i == 0 ? String(localized: "Last Turn") : "“\(m.prompt.prefix(48))” · \(when)"
            turnPop.addItem(withTitle: title)
            turnPop.lastItem?.representedObject = m.id
            turnPop.lastItem?.toolTip = m.prompt
        }
        if let picked, let i = marks.firstIndex(where: { $0.id == picked }) { turnPop.selectItem(at: i) }
        turnPop.isHidden = marks.count < 2
    }
}
