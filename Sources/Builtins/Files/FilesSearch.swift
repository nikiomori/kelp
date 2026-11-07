import AppKit
import Core
import DesignKit
import KelpKit
import Markdown
import Quartz
import WorkbenchKit

@MainActor
extension FilesPanel {
    // MARK: search
    func showContentResults(_ on: Bool) { showResults(on) }
    private func showResults(_ on: Bool) {
        resultsScroll.isHidden = !on
        leftScroll.isHidden = on || !loadError.isHidden
        if !on { noResults.show(nil) }
    }
    func showLoadError(_ message: String?) {
        if let message {
            loadError.showError(String(localized: "Couldn't list the files"), text: message)
        } else {
            loadError.show(nil)
        }
        leftScroll.isHidden = message != nil || !resultsScroll.isHidden
    }
    /// Results follow the typing (a pause of a quarter second), like Xcode's Find navigator.
    func controlTextDidChange(_ note: Notification) {
        guard note.object as? NSSearchField === search else { return }
        showSearchOptions()
        typing.after(byName ? 0.1 : 0.25) { [weak self] in
            if self?.byName == true { self?.narrowTree() } else { self?.runSearch() }
        }
    }
    /// ↓ from the field goes into the results; ↩ there opens the line.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if let edit = renaming, control === edit.field, sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc keeps the old name
            edit.field.stringValue = edit.url.lastPathComponent
            view.window?.makeFirstResponder(outline)
            return true
        }
        if control === search, sel == #selector(NSResponder.moveDown(_:)), byName, outline.numberOfRows > 0 {
            view.window?.makeFirstResponder(outline)
            outline.selectRowIndexes([firstFileRow ?? 0], byExtendingSelection: false)
            return true
        }
        guard control === search, sel == #selector(NSResponder.moveDown(_:)), !matches.isEmpty, !resultsScroll.isHidden
        else {
            return false
        }
        view.window?.makeFirstResponder(results)
        results.selectRowIndexes([0], byExtendingSelection: false)
        return true
    }
    @objc func runSearch() {
        guard !byName else {
            narrowTree()
            openFirstOnReturn()
            return
        }
        guard let current = worktree else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        showResults(!query.isEmpty)
        showPatternError(nil)
        if query.isEmpty { showReplace() }
        guard !query.isEmpty else { return }
        let options = searchOptions
        Task {
            let found = await app.tryCall(
                FilesSearch(
                    id: current.id, query: query, regex: options.regex, case: options.matchCase, word: options.wholeWord
                ))
            // A newer search, options or workspace.
            guard worktree?.id == current.id, searchOptions == options,
                search.stringValue.trimmingCharacters(in: .whitespaces) == query
            else { return }
            // Half typed, a pattern often isn't one yet: what it found last stays.
            if options.regex, let error = found.error, !matches.isEmpty {
                showPatternError(error)
                return
            }
            matches = found.value ?? []
            results.reloadData()
            showReplace()
            if let error = found.error {
                noResults.showError(String(localized: "Couldn't search"), text: error, buttons: [clearButton()])
            } else {
                noResults.show(
                    matches.isEmpty ? String(localized: "No matches for “\(query)”") : nil, symbol: "magnifyingglass",
                    buttons: [clearButton()])
            }
        }
    }
    private func showPatternError(_ detail: String?) {
        patternError.stringValue = String(localized: "Not a valid pattern")
        patternError.toolTip = detail
        patternError.isHidden = detail == nil || !replaceRow.isHidden
        resultsTop.constant = !replaceRow.isHidden ? Metrics.row + Metrics.gap : detail == nil ? 0 : Metrics.row
    }

    /// What the language servers say of the project's open files, in a search's place; errors first.
    func showProblems() {
        let found = Self.problems(in: app.latest(FileEvent.self).byKey.mapValues { $0.problems ?? [] }, root: root)
        show(references: found)
        noResults.show(
            found.isEmpty ? String(localized: "No problems in open files") : nil, symbol: "checkmark.circle",
            buttons: [clearButton()])
    }

    static func problems(in files: [String: [CodeProblem]], root: String) -> [SearchMatch] {
        let all = files.filter { $0.key.hasPrefix(root + "/") }.sorted { $0.key < $1.key }.flatMap { path, found in
            found.sorted { $0.line < $1.line }.map {
                (
                    isError: $0.isError,
                    match: SearchMatch(
                        path: String(path.dropFirst(root.count + 1)), line: $0.line + 1,
                        text: ($0.isError ? "✕ " : "⚠ ") + $0.message)
                )
            }
        }
        return all.filter(\.isError).map(\.match) + all.filter { !$0.isError }.map(\.match)
    }

    /// The replace field comes with what it would replace.
    func showReplace() {
        replaceRow.isHidden = byName || matches.isEmpty || resultsScroll.isHidden
        showPatternError(nil)
    }

    /// Back to the tree.
    private func clearButton() -> NSButton {
        ClosureButton(title: String(localized: "Clear Search")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""
            showSearchOptions()
            runSearch()
            view.window?.makeFirstResponder(outline)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let match = matches[row]
        let top = NSTextField(labelWithString: "\(match.path):\(match.line)")
        top.font = .uiDigits(11)
        top.textColor = .secondaryLabelColor
        let txt = NSTextField(labelWithString: match.text)
        txt.font = .uiMono(11)
        txt.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [top, txt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return stack
    }
    @objc func openResult() {
        let row = results.clickedRow >= 0 ? results.clickedRow : results.selectedRow
        if matches.indices.contains(row) {
            let match = matches[row]
            openFile(match.path, line: match.line)
        }
    }

    /// A line the search found: what the editor offers for a line.
    func fillResult(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard matches.indices.contains(row) else { return }
        let app = app, hit = matches[row], path = root + "/" + hit.path
        menu.add(String(localized: "Open")) { [weak self] in self?.openFile(hit.path, line: hit.line) }
        menu.add(String(localized: "Open to the Side")) {
            app.workbench.open(TabURI.file(path, line: hit.line), split: .right)
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path, lines: hit.line...hit.line) }
        menu.add(String(localized: "Copy Path and Line")) {
            FileActions(app).copyReference(path, lines: hit.line...hit.line)
        }
    }
}
