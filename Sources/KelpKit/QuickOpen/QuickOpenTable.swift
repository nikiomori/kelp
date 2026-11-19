// The palette's keys and table: up, down, return and escape, drawing the rows, and fading away.
import AppKit
import Core
import DesignKit

extension QuickOpen {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let split = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            // ↩ right after typing picks from what was typed, once that is scored.
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
            commandsOnly = false   // ⌫ past the start goes back to everything, like deleting VS Code's ">"
            list(query: "")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let setting = choosing {
                list(query: setting.query)
                return true
            }   // in a setting's choices, go back to the list and put the old value back
            hide()
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
            return true   // and the keys go back to the terminal
        default: return false
        }
    }
    /// Up and down skip the groups' headings.
    private func move(_ step: Int) {
        var row = table.selectedRow + step
        while rows.indices.contains(row), case .heading = rows[row] { row += step }
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    @objc func activate() { choose(split: false) }
    /// A click only selects a row (a double-click opens it), but with ⇧ it opens the row beside, in a split, as ⇧↩
    /// does. A row with nothing to open beside (a command, a setting) stays selected.
    @objc func clicked() { click(with: NSApp.currentEvent?.modifierFlags ?? []) }
    func click(with flags: NSEvent.ModifierFlags) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard flags.contains(.shift), rows.indices.contains(row), case .item(let it) = rows[row], it.split != nil
        else { return }
        choose(split: true)
    }
    private func choose(split: Bool) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row), case .item(let it) = rows[row] else { return }
        Self.remember(it)
        if it.value != nil {
            it.action()
            return
        }   // a setting with choices lists them, and the palette stays
        choosing = nil   // the choice is kept, so closing mustn't put the old value back
        hide()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        if split, let openSplit = it.split { openSplit() } else { it.action() }
    }
    @objc func panelResignedKey(_ notification: Notification) {
        stopChoosing()
        hide()
    }

    func numberOfRows(in table: NSTableView) -> Int { rows.count }
    func tableView(_ table: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { true } else { false }
    }
    func tableView(_ table: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(rows[row].isItem ? Metrics.rowMenu : Metrics.rowSection)
    }
    func tableView(_ table: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard case .item(let it) = rows[row] else {
            guard case .heading(let group) = rows[row] else { return nil }
            let id = NSUserInterfaceItemIdentifier("quickOpen.heading")
            if let header = table.makeView(withIdentifier: id, owner: nil) as? NSStackView,
                let heading = header.arrangedSubviews.first as? NSTextField
            {
                heading.stringValue = loc(group)
                return header
            }
            let heading = NSTextField(labelWithString: loc(group))
            heading.font = .ui(TextSize.caption, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            let header = NSStackView(views: [heading])
            header.identifier = id
            // At the rows' left edge, the palette's one edge.
            header.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.gapWide, bottom: 0, right: Metrics.gapWide)
            return header
        }
        let cell = table.makeView(withIdentifier: QuickOpenCell.id, owner: nil) as? QuickOpenCell ?? QuickOpenCell()
        var icon = it.image ?? (it.kind == "File" ? app.fileIcons.image(it.title) : NSImage.symbol(it.icon, it.kind))
        if it.image == nil, let session = it.session, let own = app.catalog.icon(session.agent, size: 18) { icon = own }
        cell.show(lead: icon, session: it.session)
        cell.title.attributedStringValue = Self.highlighted(it.title, field.stringValue)
        cell.detail.stringValue = it.detail
        cell.detail.lineBreakMode = it.kind == "Setting" ? .byTruncatingTail : .byTruncatingMiddle   // paths keep both ends, prose its start
        // With the field empty, the agents on ⌘1–⌘6 show their shortcut (counted past the heading).
        let index = itemIndex.indices.contains(row) ? itemIndex[row] : 0
        let shortcut = showingRecents && index < 6 && it.kind != "Group" ? "⌘\(index + 1)  " : ""
        cell.kind.stringValue = shortcut + (showingRecents ? loc(it.kind) : it.value.map { $0 + "  ›" } ?? "")
        cell.tick.isHidden = !it.checked   // the choice in effect gets a tick at the end, as in a menu
        cell.key.stringValue = it.key   // a command's shortcut sits at the end of the title's line, as in a menu
        cell.key.isHidden = it.key.isEmpty
        cell.show(accessory: it.accessory?())
        return cell
    }
}

extension QuickOpen {
    /// Fades the panel away, a little quicker than it came. What was chosen happens at once, without waiting for this.
    func hide() {
        guard panel.isVisible, !hiding else { return }
        guard !Motion.reduced else { return panel.orderOut(nil) }
        hiding = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // AppKit runs the completion handler on the main thread
                guard let self, self.hiding else { return }   // unless it was opened again meanwhile
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }
}
