import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A search by file name, read word by word as in a terminal. `swift daemon` keeps paths holding all the words,
/// `Sources/Daemon/` keeps a folder, `!test` leaves out paths with a word, and `:changed` keeps what git has touched.
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

    /// Lowercases and composes text, because a name on disk may spell й as и + ˘ while typing gives one character.
    /// Folded text can then be compared code unit by code unit.
    static func folded(_ text: String) -> String { text.lowercased().precomposedStringWithCanonicalMapping }

    /// Pass `folded: true` when the path went through `folded` already. The search is `.literal`, because comparing
    /// Character by Character took 360 ms per key in 200k paths.
    func matches(_ path: String, folded done: Bool = false, changed: @autoclosure () -> Bool) -> Bool {
        let key = done ? path : Self.folded(path)
        func has(_ word: String) -> Bool { key.range(of: word, options: .literal) != nil }
        return wanted.allSatisfy(has) && !left.contains(where: has) && (!changedOnly || changed())
    }
}

extension FilesPanel {
    /// The most matches shown, because more folders opening at once would hold up typing. More words in the search
    /// narrow it, so the rest can show.
    private nonisolated static let mostShown = 2000

    private var nameFilter: NameFilter? {
        byName ? Optional(NameFilter(search.stringValue)).flatMap { $0.isEmpty ? nil : $0 } : nil
    }
    var isNarrowed: Bool { nameFilter != nil }

    /// The tree to show: only the paths the name filter keeps, inside their folders.
    func treeShown(_ paths: [String], ignored: [String]) -> [FileNode] {
        guard let filter = nameFilter else { return FileNode.tree(paths, ignored: ignored) }
        if lowered.of != paths { lowered = (paths, paths.map(NameFilter.folded)) }   // fold the paths once per listing
        return FileNode.tree(Self.kept(paths, lowered.paths, by: filter, changed: Set(status.keys)))
    }

    /// Returns the first `mostShown` of `paths` that `filter` keeps. `low` holds the same paths after
    /// `NameFilter.folded`.
    nonisolated static func kept(_ paths: [String], _ low: [String], by filter: NameFilter, changed: Set<String>)
        -> [String]
    {
        let kept = paths.indices.lazy.filter {
            filter.matches(low[$0], folded: true, changed: changed.contains(paths[$0]))
        }
        return Array(kept.prefix(mostShown).map { paths[$0] })
    }

    /// Narrows the tree as the name filter is typed. Matches are found off the main thread, because each key checks
    /// every path, and the newest search wins.
    func narrowTree() {
        guard let (paths, ignored) = shownPaths else { return }
        listing += 1   // a listing still being worked out was for the old tree
        narrowing?.cancel()
        guard let filter = nameFilter else {
            sayNoMatches(false)
            return show(FileNode.tree(paths, ignored: ignored ?? []), base: (paths, ignored ?? []))
        }
        let known = lowered.of == paths ? lowered.paths : nil, changed = Set(status.keys), ticket = listing
        narrowing = Task {
            let (low, kept) = await Task.detached {
                let low = known ?? paths.map(NameFilter.folded)
                return (low, Self.kept(paths, low, by: filter, changed: changed))
            }.value
            guard !Task.isCancelled, ticket == listing else { return }   // a newer key or listing came in
            lowered = (paths, low)
            show(FileNode.tree(kept), base: nil)
            sayNoMatches(kept.isEmpty)
        }
    }

    /// Says, over the emptied tree, that no name matched, as a search of contents does (only while names are searched,
    /// because a contents search says it itself).
    func sayNoMatches(_ none: Bool) {
        guard byName else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        noResults.show(
            none ? String(localized: "No Matches for “\(query)”") : nil, symbol: "magnifyingglass",
            buttons: [clearButton()])
    }

    private func show(_ tree: [FileNode], base: (paths: [String], ignored: [String])?) {
        nodes = tree
        treeBase = base
        outline.reloadData()
        if isNarrowed { outline.expandItem(nil, expandChildren: true) }
    }

    /// An empty folder says so where the tree would be, with the way to start one.
    func showNoFiles() {
        let add = ClosureButton(title: String(localized: "New File")) { [weak self] in self?.newFile() }
        loadError.show(String(localized: "No Files Yet"), symbol: "folder", buttons: [add])
    }

    var firstFileRow: Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.children == nil }
    }

    /// Once the tree is narrowed, ↩ in the field opens the first file left, and ⇧↩ opens it beside.
    func openFirstOnReturn() {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
        let beside = event.modifierFlags.contains(.shift), narrowed = narrowing
        Task {
            await narrowed?.value
            openFirst(beside: beside)
        }
    }

    private func openFirst(beside: Bool) {
        guard isNarrowed, let row = firstFileRow, let node = outline.item(atRow: row) as? FileNode else { return }
        if beside {
            app.workbench.open(TabURI.file(root + "/" + node.path), split: .right)
        } else {
            openFile(node.path)
        }
    }

    func findByName() {
        searchBy(name: true)
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    /// Sets up the rows under the search bar: the replace field, and the label that says what's wrong with a pattern.
    func setUpSearchRows() {
        patternError.font = .ui(TextSize.caption)
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

    /// Sets up the magnifier menu in the search field, which chooses what to search, as in Finder and Mail. The choice
    /// is kept.
    func setUpSearchMode() {
        let menu = NSMenu()
        for (title, name) in [(String(localized: "File Names"), true), (String(localized: "File Contents"), false)] {
            menu.add(title) { [weak self] in self?.searchBy(name: name) }.state = byName == name ? .on : .off
        }
        (search.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
        search.placeholderString =
            byName ? String(localized: "Find File by Name") : String(localized: "Search in Files")
    }

    func searchBy(name: Bool) {
        guard name != byName else { return }
        byName = name
        UserDefaults.standard.set(name, forKey: "files.searchByName")
        setUpSearchMode()
        results.show([])
        narrowTree()
        showSearchOptions()
        if !name { runSearch() } else { showContentResults(false) }
        showReplace()
    }
}
