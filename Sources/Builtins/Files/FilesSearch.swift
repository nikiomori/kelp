import AppKit
import Core
import DesignKit
import KelpKit
import Quartz

@MainActor
extension FilesPanel {
    // MARK: search
    func showContentResults(_ on: Bool) { showResults(on) }
    private func showResults(_ on: Bool) {
        // The tree and the results take each other's place in a fade, once per switch, not per key.
        if results.scroll.isHidden == on { results.scroll.superview?.crossfade() }
        results.scroll.isHidden = !on
        leftScroll.isHidden = on || !loadError.isHidden
        if !on { noResults.show(nil) }
    }
    func showLoadError(_ message: String?) {
        if let message {
            loadError.showError(String(localized: "Couldn’t list the files"), text: message)
        } else {
            loadError.show(nil)
        }
        leftScroll.isHidden = message != nil || !results.scroll.isHidden
    }
    /// Results follow the typing after a short pause (a quarter second for contents, a tenth for names), like Xcode's
    /// Find navigator.
    func controlTextDidChange(_ note: Notification) {
        guard note.object as? NSSearchField === search else { return }
        showSearchOptions()
        typing.after(byName ? 0.1 : 0.25) { [weak self] in
            if self?.byName == true { self?.narrowTree() } else { self?.runSearch() }
        }
    }
    /// ↓ from the field moves into the results (or into the tree when searching by name), and ↩ there opens the line.
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
        guard control === search, sel == #selector(NSResponder.moveDown(_:)), !results.matches.isEmpty,
            !results.scroll.isHidden
        else {
            return false
        }
        view.window?.makeFirstResponder(results.table)
        results.table.selectRowIndexes([0], byExtendingSelection: false)
        return true
    }
    /// ⇧⌘F (Find in Workspace) goes straight into this field. Pressed again there, it goes back to the tab you were in.
    func findInFiles() {
        guard let window = view.window else { return }
        searchBy(name: false)
        if window.firstResponder === search.currentEditor() {
            app.workbench.focusTab()
            return
        }
        window.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    /// Shows a list from a language server, such as references, where search results go.
    func show(references found: [SearchMatch], errors: [Bool]? = nil) {
        searchBy(name: false)
        search.stringValue = ""
        results.show(found, errors: errors)
        showContentResults(true)
        noResults.show(nil)
        replaceRow.isHidden = true   // a server's list is changed through Rename, not Replace
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
        searching?.cancel()   // the daemon also stops the old rg when the next search starts (`replaces`)
        searching = Task {
            let found = await app.tryCall(
                FilesSearch(
                    id: current.id, query: query, regex: options.regex, case: options.matchCase,
                    word: options.wholeWord,
                    replaces: true))
            // Drops the result when a newer search, new options or another workspace came in meanwhile.
            guard !Task.isCancelled, worktree?.id == current.id, searchOptions == options,
                search.stringValue.trimmingCharacters(in: .whitespaces) == query
            else { return }
            // A half-typed pattern often isn't valid yet, so the last results stay.
            if options.regex, let error = found.error, !results.matches.isEmpty {
                showPatternError(error)
                return
            }
            results.show(found.value ?? [])
            showReplace()
            if let error = found.error {
                noResults.showError(String(localized: "Couldn’t search"), text: error, buttons: [clearButton()])
            } else {
                noResults.show(
                    results.matches.isEmpty ? String(localized: "No matches for “\(query)”") : nil,
                    symbol: "magnifyingglass",
                    buttons: [clearButton()])
            }
        }
    }
    private func showPatternError(_ detail: String?) {
        patternError.stringValue = String(localized: "Not a valid pattern")
        patternError.toolTip = detail
        patternError.isHidden = detail == nil || !replaceRow.isHidden
        let row = TextSize.of(Metrics.row)   // the rows grow with Text size
        let top = !replaceRow.isHidden ? row + Metrics.gap : detail == nil ? 0 : row
        guard top != resultsTop.constant else { return }
        // The results slide down to make room for the error line and back up, instead of jumping a row with every key
        // of a pattern being typed.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = view.window == nil ? 0 : Motion.duration(Motion.fast)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            resultsTop.animator().constant = top
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Shows what the language servers report about the project's open files, in place of search results, errors
    /// first.
    func showProblems() {
        let found = Self.problems(in: app.latest(FileEvent.self).byKey.mapValues { $0.problems ?? [] }, root: root)
        show(references: found.map(\.match), errors: found.map(\.isError))
        noResults.show(
            found.isEmpty ? String(localized: "No problems in open files") : nil, symbol: "checkmark.circle",
            buttons: [clearButton()])
    }

    /// The project's problems, errors first, each with whether it is an error (the list draws its sign).
    static func problems(in files: [String: [CodeProblem]], root: String) -> [(isError: Bool, match: SearchMatch)] {
        let all = files.filter { $0.key.hasPrefix(root + "/") }.sorted { $0.key < $1.key }.flatMap { path, found in
            found.sorted { $0.line < $1.line }.map {
                (
                    isError: $0.isError,
                    match: SearchMatch(
                        path: String(path.dropFirst(root.count + 1)), line: $0.line + 1,
                        text: $0.message)
                )
            }
        }
        return all.filter(\.isError) + all.filter { !$0.isError }
    }

    /// Shows the replace field only while there are content matches for it to replace.
    func showReplace() {
        replaceRow.isHidden = byName || results.matches.isEmpty || results.scroll.isHidden
        showPatternError(nil)
    }

    /// A button that clears the search and goes back to the tree.
    private func clearButton() -> NSButton {
        ClosureButton(title: String(localized: "Clear Search")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""
            showSearchOptions()
            runSearch()
            view.window?.makeFirstResponder(outline)
        }
    }
}
