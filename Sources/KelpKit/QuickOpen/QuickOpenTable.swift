// The palette's keys and table: up, down, return and escape, the rows drawn, and the fade away.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension QuickOpen {
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let split = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            // ↩ right after typing picks from what was typed, once it's scored.
            if let pending = scoring {
                Task {
                    await pending.value
                    choose(split: split)
                }
            } else {
                choose(split: split)
            }
            return true
        case #selector(NSResponder.deleteBackward(_:))
        where commandsOnly && choosing == nil && field.stringValue.isEmpty:
            commandsOnly = false   // ⌫ past the start: back to everything, as deleting VS Code's ">"
            list(query: "")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let setting = choosing {
                list(query: setting.query)
                return true
            }   // a setting's choices: back to the list, the old value back
            hide()
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
            return true   // back to the terminal
        default: return false
        }
    }
    /// Up and down skip the groups' headings.
    private func move(_ d: Int) {
        var row = table.selectedRow + d
        while rows.indices.contains(row), case .heading = rows[row] { row += d }
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    @objc func activate() { choose(split: false) }
    private func choose(split: Bool) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row), case .item(let it) = rows[row] else { return }
        Self.remember(it)
        if it.value != nil {
            it.action()
            return
        }   // a setting with choices lists them; the palette stays
        choosing = nil   // the choice is kept: closing mustn't put the old value back
        hide()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        if split, let openSplit = it.split { openSplit() } else { it.action() }
    }
    @objc func panelResignedKey(_ n: Notification) {
        stopChoosing()
        hide()
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { true } else { false }
    }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(rows[row].isItem ? Metrics.rowMenu : Metrics.row)
    }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard case .item(let it) = rows[row] else {
            guard case .heading(let group) = rows[row] else { return nil }
            let heading = NSTextField(labelWithString: loc(group))
            heading.font = .ui(TextSize.caption, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            let header = NSStackView(views: [heading])
            header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)
            return header
        }
        let img = NSImageView(
            image: it.image ?? (it.kind == "File" ? app.fileIcons.image(it.title) : NSImage.symbol(it.icon, it.kind)))
        img.contentTintColor = .secondaryLabelColor
        // An agent: its state while there's something to see (as on its tab), else its own icon.
        let lead: NSView
        if let session = it.session,
            [.working, .waiting, .error].contains(session.status) || (session.status == .done && session.unread)
        {
            let mark = StatusMark(size: 14)
            mark.status = session.status
            mark.unread = session.unread
            mark.waitsForCommand = session.waitsForCommand
            let box = NSView()
            mark.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                box.heightAnchor.constraint(equalToConstant: 18)
            ])
            lead = box
        } else {
            if let session = it.session, let icon = app.catalog.icon(session.agent, size: 18) { img.image = icon }
            lead = img
        }
        let t1 = NSTextField(labelWithString: "")
        t1.attributedStringValue = Self.highlighted(it.title, field.stringValue)
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: it.detail)
        t2.font = .ui(TextSize.row)
        t2.textColor = .secondaryLabelColor
        t2.lineBreakMode = it.kind == "Setting" ? .byTruncatingTail : .byTruncatingMiddle   // paths keep both ends, prose its start
        // Empty field: the agents on ⌘1–⌘6 say so (counted past the heading).
        let index = rows[..<row].filter { if case .item = $0 { true } else { false } }.count
        let shortcut = showingRecents && index < 6 && it.kind != "Group" ? "⌘\(index + 1)  " : ""
        let kind = NSTextField(
            labelWithString: shortcut + (showingRecents ? loc(it.kind) : it.value.map { $0 + "  ›" } ?? ""))
        kind.font = .ui(TextSize.caption)
        kind.textColor = .secondaryLabelColor
        // The choice in effect: a tick at the end, as in a menu.
        let tick = NSImageView(image: .symbol("checkmark", String(localized: "Current")))
        tick.contentTintColor = .themeAccent
        tick.isHidden = !it.checked
        // A command's shortcut: at the end of the title's line, as in a menu.
        let key = NSTextField(labelWithString: it.key)
        key.font = .ui(TextSize.row)
        key.textColor = .secondaryLabelColor
        key.isHidden = it.key.isEmpty
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        key.setContentHuggingPriority(.required, for: .horizontal)
        // One line, as Xcode's Open Quickly: the name, then where it is in grey, which gives way first.
        t1.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        t1.setContentHuggingPriority(.required, for: .horizontal)
        t2.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        t2.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the row's width, so the shortcut sits at its end
        let stack = NSStackView(views: [lead, t1, t2, key, kind, tick])
        stack.spacing = Metrics.gapWide
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        lead.widthAnchor.constraint(equalToConstant: 18).isActive = true
        for v in [kind, tick] { v.setContentHuggingPriority(.required, for: .horizontal) }
        let cell = PaletteCell()   // its words turn light on the accent
        cell.pin(stack)
        return cell
    }
}

extension QuickOpen {
    /// Away, a little quicker than it came; what was chosen happens at once, without waiting for this.
    func hide() {
        guard panel.isVisible, !hiding else { return }
        guard !Motion.reduced else { return panel.orderOut(nil) }
        hiding = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs it on the main thread
                guard let self, self.hiding else { return }   // opened again meanwhile
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }
}
