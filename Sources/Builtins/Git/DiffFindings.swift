import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Review comments as findings to pick from (a reviewer agent's or the user's): each open one has a box saying whether
/// it goes to the agent with Send to Agent (Space flips it on the selected comment), "Fix This One" sends it alone, and
/// "Dismiss" resolves it.
extension DiffViewController {
    func commentRow(_ c: DiffComment) -> NSView {
        let who = c.author.map { "\($0): " } ?? ""
        let text = label(
            "💬 \(who)\(c.text)" + (c.state == .open ? "" : "  [\(c.state.rawValue)]"),
            font: .ui(TextSize.caption, weight: .medium))
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [text]
        if c.state == .open {
            let box = ClosureButton(title: "") { [weak self] in self?.flip(c.id) }
            box.setButtonType(.switch)
            box.state = notes.skipped.contains(c.id) ? .off : .on
            box.toolTip = String(localized: "Send to Agent with the others")
            views.insert(box, at: 0)
            for (title, run) in [
                (String(localized: "Fix This One"), { [weak self] in self?.send([c.id]) }),
                (String(localized: "Dismiss"), { [weak self] in self?.dismiss(c.id) })
            ] as [(String, () -> Void)] {
                let button = ClosureButton(title: title, action: run)
                button.bezelStyle = .inline
                button.controlSize = .small
                views.append(button)
            }
            views.insert(NSView(), at: 2)   // the room goes between the text and its buttons
            views[2].setContentHuggingPriority(.init(1), for: .horizontal)
        }
        let row = NSStackView(views: views)
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gapWide)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.fillSelected.cgColor
        return row
    }

    /// Space on a selected comment: in or out of what Send to Agent sends.
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

    /// The open comments still ticked.
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
            guard let count = await app.call(CommentSend(id: wid, session: sid, only: ids)) else { return }   // the banner says why
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
