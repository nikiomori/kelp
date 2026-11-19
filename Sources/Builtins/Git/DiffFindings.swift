import AppKit
import Core
import DesignKit
import KelpKit

/// Review comments (a reviewer agent's or the user's) shown as findings to pick from. Each open comment has a box that
/// says whether Send to Agent sends it to the agent; Space flips the box on the selected comment. "Fix This One" sends
/// that comment alone, and "Dismiss" resolves it.
extension DiffViewController {
    func commentRow(_ diffComment: DiffComment) -> NSView {
        let who = diffComment.author.map { "\($0): " } ?? ""
        let text = NSTextField.label("\(who)\(diffComment.text)", font: .ui(TextSize.caption, weight: .medium))
        let bubble = NSImageView(image: .symbol("text.bubble", String(localized: "Comment")))
        bubble.symbolConfiguration = .chrome(Metrics.iconSmall)
        bubble.contentTintColor = .secondaryLabelColor
        var views: [NSView] = [bubble, text]
        if let word = Self.stateWord(diffComment.state) {   // a comment that was sent or resolved says so, in grey
            views.append(NSTextField.label(word, font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        if diffComment.state == .open {
            let box = ClosureButton(title: "") { [weak self] in self?.flip(diffComment.id) }
            box.setButtonType(.switch)
            box.state = notes.skipped.contains(diffComment.id) ? .off : .on
            box.toolTip = String(localized: "Send to Agent with the others")
            views.insert(box, at: 0)
            let actions: [(String, @MainActor () -> Void)] = [
                (String(localized: "Fix This One"), { [weak self] in self?.send([diffComment.id]) }),
                (String(localized: "Dismiss"), { [weak self] in self?.dismiss(diffComment.id) })
            ]
            for (title, run) in actions {
                let button = ClosureButton(title: title, action: run)
                button.bezelStyle = .inline
                button.controlSize = .small
                views.append(button)
            }
            views.insert(NSView(), at: 3)   // the room goes between the text and its buttons
            views[3].setContentHuggingPriority(.init(1), for: .horizontal)
        }
        let row = FillStack(views: views)
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gapWide)
        row.fill = .fillRest
        return row
    }

    /// What a comment's row says of a comment that is no longer open: "sent" or "resolved".
    static func stateWord(_ state: DiffComment.State) -> String? {
        switch state {
        case .open: nil
        case .sent: String(localized: "sent", comment: "A review comment that was sent to the agent")
        case .resolved: String(localized: "resolved", comment: "A review comment that was dismissed or fixed")
        }
    }

    /// Space on a selected comment puts it in or out of what Send to Agent sends.
    func flipSelectedComment() -> Bool {
        guard rows.indices.contains(table.selectedRow), case .comment(let comment) = rows[table.selectedRow],
            comment.state == .open
        else { return false }
        flip(comment.id)
        return true
    }

    private func flip(_ id: String) {
        if notes.skipped.contains(id) { notes.skipped.remove(id) } else { notes.skipped.insert(id) }
        if let index = rows.firstIndex(where: { if case .comment(let comment) = $0 { comment.id == id } else { false } }
        ) {
            table.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    /// The ids of the open comments that are still ticked.
    var picked: [String] { notes.saved.filter { $0.state == .open && !notes.skipped.contains($0.id) }.map(\.id) }

    @objc func sendComments() { send(picked) }

    func send(_ ids: [String]) {
        guard let wid = worktreeId else { return }
        guard !ids.isEmpty else {
            status.stringValue = String(localized: "No open comments ticked")
            return
        }
        Task {
            guard let sid = await pickAgentSession(wid) else { return }
            // On failure the banner says why.
            guard let count = await app.call(CommentSend(id: wid, session: sid, only: ids)) else { return }
            status.stringValue = String(localized: "Sent \(count) comments to agent")
            await load()
        }
    }

    private func dismiss(_ id: String) {
        Task {
            await app.call(CommentSetState(id: id, state: "resolved"))
            await load()
        }
    }
}
