import AppKit
import Core
import DesignKit
import WorkbenchKit

/// What ⌘F in a diff found: the text, the rows holding it, the one stepped to, and its card.
struct DiffFinding {
    var needle = "", rows: [Int] = [], at = -1
    /// Counts searches: one a newer search or new rows overtook drops what it found, and waits for that one (`latest`).
    var searches = 0
    var latest: Task<Void, Never>?
    /// A search still to show that goes to the first match: one that overtakes it (a reload's) goes there too.
    var stepping = false
    var card: FindCard?
}

/// ⌘F in a diff looks through every file's lines, marks each match, and ⌘G / ⇧⌘G step through them.
extension DiffViewController {
    @objc func performFindPanelAction(_ sender: Any?) {
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: stepFind(next: true)
        case .previous?: stepFind(next: false)
        default: findCard().begin(nil)
        }
    }

    private func findCard() -> FindCard {
        if let existing = find.card { return existing }
        let card = FindCard()
        card.onSearch = { [weak self] in self?.search($0) }
        card.onStep = { [weak self] in self?.stepFind(next: $0) }
        card.onClose = { [weak self] in
            guard let self else { return }
            search("")
            view.window?.makeFirstResponder(table)
        }
        card.float(in: view, top: table.enclosingScrollView ?? table)
        find.card = card
        return card
    }

    /// The lines holding `needle` (any case), in every file. `step`: go to the first; a diff read again keeps its place.
    /// The rows are looked through off the main thread: a big diff is a lot of lines, and each new load looks again.
    /// The task ends once this search, or the one that overtook it, shows what it found.
    @discardableResult
    func search(_ needle: String, step: Bool = true) -> Task<Void, Never> {
        find.needle = needle
        find.searches += 1
        find.stepping = find.stepping || step
        let generation = find.searches, all = rows
        let task = Task {
            let found =
                needle.isEmpty
                ? []
                : await Task.detached {
                    all.indices.filter { index in
                        Self.texts(all[index]).contains { $0.range(of: needle, options: .caseInsensitive) != nil }
                    }
                }.value
            guard generation == find.searches else { return await find.latest?.value ?? () }
            let stepping = find.stepping
            find.stepping = false
            show(found, step: stepping)
        }
        find.latest = task
        return task
    }

    private func show(_ found: [Int], step: Bool) {
        let needle = find.needle
        find.rows = found
        find.at = step || find.at >= find.rows.count ? -1 : find.at
        find.card?.total = needle.isEmpty ? -1 : find.rows.count
        find.card?.selected = find.at
        table.reloadData()   // the marks
        if step, !find.rows.isEmpty { stepFind(next: true) }
    }

    func stepFind(next: Bool) {
        let count = find.rows.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        find.at = next ? (find.at + 1) % count : (max(find.at, 0) - 1 + count) % count
        let row = find.rows[find.at]
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(min(row + 4, rows.count - 1))
        table.scrollRowToVisible(row)
        find.card?.selected = find.at
    }

    nonisolated private static func texts(_ row: ReviewRow) -> [String] {
        switch row {
        case .diff(.line(_, let line)): [line.text]
        case .diff(.pair(_, let removed, let added)): [removed?.text, added?.text].compactMap { $0 }
        default: []
        }
    }

    /// Every match of the find's text in a shown line, past its first `from` characters (the +/- marker).
    func markFound(_ s: NSMutableAttributedString, from: Int) {
        guard !find.needle.isEmpty else { return }
        let text = s.string as NSString
        var rest = NSRange(location: from, length: text.length - from)
        while case let match = text.range(of: find.needle, options: .caseInsensitive, range: rest),
            match.location != NSNotFound
        {
            // Dark text on the find colour, as Xcode marks a match: grey comment text on yellow can't be read.
            s.addAttributes(
                [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: match)
            rest = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
        }
    }
}
