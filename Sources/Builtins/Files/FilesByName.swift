import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The words of a search by file name, as in a terminal: `swift daemon` (all of them, in the path), `Sources/Daemon/` a
/// folder, `!test` to leave out, `:changed` what git has touched.
struct NameFilter: Equatable {
    private(set) var wanted: [String] = [], left: [String] = [], changedOnly = false

    init(_ query: String) {
        for word in Self.folded(query).split(separator: " ").map(String.init) {
            if word == ":changed" {
                changedOnly = true
            } else if word.hasPrefix("!"), word.count > 1 {
                left.append(String(word.dropFirst()))
            } else {
                wanted.append(word)
            }
        }
    }

    var isEmpty: Bool { wanted.isEmpty && left.isEmpty && !changedOnly }

    /// Lower case and composed (a name on disk may have й as и + ˘, typed it's one): compared code unit by code unit then.
    static func folded(_ s: String) -> String { s.lowercased().precomposedStringWithCanonicalMapping }

    /// `folded`: the path went through `folded` already. `.literal`: a key in 200k paths took 360 ms, Character by Character.
    func matches(_ path: String, folded done: Bool = false, changed: @autoclosure () -> Bool) -> Bool {
        let p = done ? path : Self.folded(path)
        func has(_ w: String) -> Bool { p.range(of: w, options: .literal) != nil }
        return wanted.allSatisfy(has) && !left.contains(where: has) && (!changedOnly || changed())
    }
}

extension FilesPanel {
    /// So many folders opening at once would hold up the keys: the rest is a word away.
    private static let mostShown = 2000

    private var nameFilter: NameFilter? { byName ? Optional(NameFilter(search.stringValue)).flatMap { $0.isEmpty ? nil : $0 } : nil }
    var isNarrowed: Bool { nameFilter != nil }

    /// The tree as it's to show: only what the name filter keeps, folders keeping their shape.
    func treeShown(_ paths: [String], ignored: [String]) -> [FileNode] {
        guard let filter = nameFilter else { return FileNode.tree(paths, ignored: ignored) }
        if lowered.of != paths { lowered = (paths, paths.map(NameFilter.folded)) }   // the same listing: one buffer, compared at once
        let low = lowered.paths
        let kept = paths.indices.lazy.filter { filter.matches(low[$0], folded: true, changed: self.status[paths[$0]] != nil) }
        return FileNode.tree(Array(kept.prefix(Self.mostShown).map { paths[$0] }))
    }

    func narrowTree() {
        guard let (paths, ignored) = shownPaths else { return }
        nodes = treeShown(paths, ignored: ignored ?? [])
        outline.reloadData()
        if isNarrowed { outline.expandItem(nil, expandChildren: true) }
    }

    var firstFileRow: Int? { (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.children == nil } }

    /// ↩ in the field opens the first file left; ⇧↩ beside.
    func openFirstOnReturn() {
        guard isNarrowed, NSApp.currentEvent?.type == .keyDown, let row = firstFileRow, let n = outline.item(atRow: row) as? FileNode else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            app.workbench.open(TabURI.file(root + "/" + n.path), split: .right)
        } else {
            openFile(n.path)
        }
    }

    /// ⇧⌘F (Find in Workspace): straight into this field; pressed again there, back to what you were doing.
    func findInFiles() {
        guard let w = view.window else { return }
        searchBy(name: false)
        if w.firstResponder === search.currentEditor() { app.workbench.editor?.focusSelected(); return }
        w.makeFirstResponder(search); search.currentEditor()?.selectAll(nil)
    }

    /// A language server's list where a search's goes.
    func show(references found: [SearchMatch]) {
        searchBy(name: false)
        search.stringValue = ""
        matches = found
        results.reloadData()
        showContentResults(true)
        noResults.show(nil)
        replaceRow.isHidden = true   // a server's list: Rename is the way to change it
    }

    func findByName() {
        searchBy(name: true)
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    /// What sits under the bar: the replace field and what's wrong with a pattern.
    func setUpSearchRows() {
        patternError.font = .ui(11)
        patternError.textColor = .textRed
        patternError.lineBreakMode = .byTruncatingTail
        patternError.isHidden = true
        replaceField.placeholderString = String(localized: "Replace")
        replaceField.controlSize = .small
        (replaceField.cell as? NSSearchFieldCell)?.searchButtonCell?.isTransparent = true
        replaceButton.controlSize = .small
        replaceRow.spacing = Metrics.gap
        replaceRow.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.insetTrailing)
        replaceRow.isHidden = true
    }

    /// The field's magnifier chooses, as Finder's and Mail's do; the choice stays.
    func setUpSearchMode() {
        let menu = NSMenu()
        for (title, name) in [(String(localized: "File Names"), true), (String(localized: "File Contents"), false)] {
            menu.add(title) { [weak self] in self?.searchBy(name: name) }.state = byName == name ? .on : .off
        }
        (search.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
        search.placeholderString = byName ? String(localized: "Find File by Name") : String(localized: "Search in Files")
    }

    func searchBy(name: Bool) {
        guard name != byName else { return }
        byName = name
        UserDefaults.standard.set(name, forKey: "files.searchByName")
        setUpSearchMode()
        matches = []
        results.reloadData()
        narrowTree()
        showSearchOptions()
        if !name { runSearch() } else { showContentResults(false) }
        showReplace()
    }
}
