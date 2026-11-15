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
    static func folded(_ text: String) -> String { text.lowercased().precomposedStringWithCanonicalMapping }

    /// `folded`: the path went through `folded` already. `.literal`: a key in 200k paths took 360 ms, Character by Character.
    func matches(_ path: String, folded done: Bool = false, changed: @autoclosure () -> Bool) -> Bool {
        let key = done ? path : Self.folded(path)
        func has(_ word: String) -> Bool { key.range(of: word, options: .literal) != nil }
        return wanted.allSatisfy(has) && !left.contains(where: has) && (!changedOnly || changed())
    }
}

extension FilesPanel {
    /// So many folders opening at once would hold up the keys: the rest is a word away.
    private nonisolated static let mostShown = 2000

    private var nameFilter: NameFilter? {
        byName ? Optional(NameFilter(search.stringValue)).flatMap { $0.isEmpty ? nil : $0 } : nil
    }
    var isNarrowed: Bool { nameFilter != nil }

    /// The tree as it's to show: only what the name filter keeps, folders keeping their shape.
    func treeShown(_ paths: [String], ignored: [String]) -> [FileNode] {
        guard let filter = nameFilter else { return FileNode.tree(paths, ignored: ignored) }
        if lowered.of != paths { lowered = (paths, paths.map(NameFilter.folded)) }   // the same listing: one buffer, compared at once
        return FileNode.tree(Self.kept(paths, lowered.paths, by: filter, changed: Set(status.keys)))
    }

    /// The first `mostShown` of `paths` (`low`: as `NameFilter.folded` makes them) that `filter` keeps.
    nonisolated static func kept(_ paths: [String], _ low: [String], by filter: NameFilter, changed: Set<String>)
        -> [String]
    {
        let kept = paths.indices.lazy.filter {
            filter.matches(low[$0], folded: true, changed: changed.contains(paths[$0]))
        }
        return Array(kept.prefix(mostShown).map { paths[$0] })
    }

    /// As the name filter is typed: what it keeps is found off the main thread (every path, every key), the newest wins.
    func narrowTree() {
        guard let (paths, ignored) = shownPaths else { return }
        listing += 1   // a listing being worked out was for the tree as it was
        narrowing?.cancel()
        guard let filter = nameFilter else {
            return show(FileNode.tree(paths, ignored: ignored ?? []), base: (paths, ignored ?? []))
        }
        let known = lowered.of == paths ? lowered.paths : nil, changed = Set(status.keys), ticket = listing
        narrowing = Task {
            let (low, kept) = await Task.detached {
                let low = known ?? paths.map(NameFilter.folded)
                return (low, Self.kept(paths, low, by: filter, changed: changed))
            }.value
            guard !Task.isCancelled, ticket == listing else { return }   // a newer key, or a newer listing
            lowered = (paths, low)
            show(FileNode.tree(kept), base: nil)
        }
    }

    private func show(_ tree: [FileNode], base: (paths: [String], ignored: [String])?) {
        nodes = tree
        treeBase = base
        outline.reloadData()
        if isNarrowed { outline.expandItem(nil, expandChildren: true) }
    }

    var firstFileRow: Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.children == nil }
    }

    /// ↩ in the field opens the first file left, once the tree is narrowed; ⇧↩ beside.
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

    /// What sits under the bar: the replace field and what's wrong with a pattern.
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

    /// The field's magnifier chooses, as Finder's and Mail's do; the choice stays.
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
