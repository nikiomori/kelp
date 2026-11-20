import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// One file in a replacement: its text as read, the version that was read, and which of its matches are replaced.
struct ReplaceFile {
    let path: String, name: String, text: String, stamp: FileStamp, matches: [ReplaceMatch]
    var chosen: Set<Int>
    var result: String {
        ReplaceInText.applying(matches.enumerated().filter { chosen.contains($0.offset) }.map(\.element), to: text)
    }

    /// What Replace All says when there's nothing to show. Files it couldn't read are named, because they aren't the
    /// same as files with nothing to change.
    static func nothingWords(unread: [String], failure: String?) -> String {
        guard let first = unread.first else { return String(localized: "Nothing to replace.") }
        let which = unread.count == 1 ? first : String(localized: "\(first) and \(unread.count - 1) more")
        return String(localized: "Couldn’t read \(which): \(failure ?? "")")
    }
}

@MainActor
extension FilesPanel {
    /// Replace All: reads the files the search found, shows what would change, and writes what the user chooses. A file
    /// with unsaved edits is left out, because what's on disk isn't what's in its tab.
    func replaceAll() {
        let template = replaceField.stringValue, query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let names = Array(Set(results.matches.map(\.path))).sorted(), root = root, app = app
        let options = searchOptions
        // Paths are compared with symlinks resolved, because a tab may name its file through a link (/tmp,
        // /private/tmp).
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let edited = Set(app.workbench.editedFiles.compactMap { $0.fileURL.map { real($0.path) } })
        replaceButton.isEnabled = false   // busy while the files are read, so a second click doesn't start again
        Task { @MainActor in
            var files: [ReplaceFile] = [], unread: [String] = [], failure: String?
            for name in names where !edited.contains(real(root + "/" + name)) {
                let (read, error) = await app.tryCall(FilesRead(path: root + "/" + name))
                guard let contents = read else {
                    unread.append(name)
                    failure = failure ?? error
                    continue
                }
                do {
                    let text = contents.text   // the regex runs off the main thread, since a file can be big
                    let plan = try await Task.detached { [options] in
                        try ReplaceInText.plan(text, query: query, options: options, template: template)
                    }.value
                    if plan.isEmpty { continue }
                    files.append(
                        ReplaceFile(
                            path: root + "/" + name, name: name, text: contents.text, stamp: contents.stamp,
                            matches: plan,
                            chosen: Set(plan.indices)))
                } catch {
                    replaceButton.isEnabled = true
                    return Banner.show(String(localized: "Not a valid pattern"), style: .error)
                }
            }
            replaceButton.isEnabled = true
            guard !files.isEmpty else {
                let why = ReplaceFile.nothingWords(unread: unread, failure: failure)
                return Banner.show(why, style: unread.isEmpty ? .info : .error)
            }
            let sheet = ReplaceSheet(files, leftOut: names.count - files.count)
            guard let window = sheet.window, await runSheet(window) == .OK else { return }
            await Self.write(sheet.files, app: app)
            self.runSearch()   // the files changed, so the search runs again
        }
    }

    /// Writes the chosen files, each only over the version that was read. One Undo puts every file back, again only
    /// over the version written.
    static func write(_ files: [ReplaceFile], app: AppModel) async {
        var undo: [FileBatch.Done] = [], refused: [String] = []
        for file in files where !file.chosen.isEmpty {
            if let stamp = await FileBatch.write(file.path, file.result, over: file.stamp, app: app) {
                undo.append(FileBatch.Done(path: file.path, old: file.text, stamp: stamp))
            } else {
                refused.append(file.name)
            }
        }
        let note =
            refused.isEmpty
            ? ""
            : " " + String(localized: "Changed since it was read, so left alone: \(refused.joined(separator: ", ")).")
        Banner.show(
            String(localized: "Replaced in \(undo.count) files.") + note,
            action: (
                String(localized: "Undo"),
                {
                    Task { await FileBatch.undoSaying(undo, app: app) }
                }
            ))
    }
}

/// The sheet showing what a replacement would change, file by file, with a checkbox on each file and each match.
@MainActor
final class ReplaceSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var files: [ReplaceFile]
    let window: NSWindow?
    private let table = NSTableView()
    private let go = NSButton(title: "", target: nil, action: nil)
    /// The table's rows. Each row is a file, or one match in a file.
    private let rows: [(file: Int, match: Int?)]
    private static let width: CGFloat = 640   // wider than a form, to fit the lines of code it lists

    init(_ files: [ReplaceFile], leftOut: Int) {
        self.files = files
        rows = files.indices.flatMap { index in
            [(index, nil)] + files[index].matches.indices.map { (index, Optional($0)) }
        }
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 460), styleMask: [.titled], backing: .buffered,
            defer: true)
        super.init()
        let column = NSTableColumn(identifier: .init("r"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let left =
            leftOut > 0
            ? String(localized: "\(leftOut) files with unsaved edits or nothing to change are left out.") : ""
        let note = NSTextField(wrappingLabelWithString: left)
        note.font = .ui(TextSize.caption)
        note.textColor = .secondaryLabelColor
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        go.target = self
        go.action = #selector(confirmed)
        go.keyEquivalent = "\r"
        let buttons = NSStackView(views: [note, NSView(), cancel, go])
        buttons.spacing = Metrics.gapWide
        window?.contentView = SheetForm.stack([scroll, buttons], wide: [scroll, buttons], width: Self.width)
        count()
    }

    private func count() {
        let total = files.reduce(0) { $0 + $1.chosen.count }
        go.title = String(localized: "Replace \(total)")
        go.isEnabled = total > 0
    }

    @objc private func cancelled() { finish(.cancel) }
    @objc private func confirmed() { finish(.OK) }
    private func finish(_ response: NSApplication.ModalResponse) {
        if let window { window.sheetParent?.endSheet(window, returnCode: response) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let (fileIndex, matchIndex) = rows[row]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = row
        guard let matchIndex else {
            box.title = files[fileIndex].name
            box.state =
                files[fileIndex].chosen.isEmpty
                ? .off : files[fileIndex].chosen.count == files[fileIndex].matches.count ? .on : .mixed
            box.font = .ui(TextSize.row, weight: .medium)   // the file over its lines
            return box
        }
        let match = files[fileIndex].matches[matchIndex]
        box.state = files[fileIndex].chosen.contains(matchIndex) ? .on : .off
        // As the diff draws them: the code in the text's colour on the line's tint, the changed part on the word's.
        func line(_ sign: String, _ text: String, _ other: String, _ fill: NSColor, _ word: NSColor) -> NSTextField {
            let font = NSFont.uiMono(TextSize.caption), field = NSTextField.label("", font: font)
            let shown = NSMutableAttributedString(
                string: sign, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let code = NSMutableAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            code.addAttribute(.backgroundColor, value: word, range: Self.changed(text, from: other))
            shown.append(code)
            field.attributedStringValue = shown
            field.drawsBackground = true
            field.backgroundColor = fill
            return field
        }
        let lines = NSStackView(views: [
            line("\(match.line) − ", match.before, match.after, .diffRemoved, .diffRemovedWord),
            line("\(match.line) + ", match.after, match.before, .diffAdded, .diffAddedWord)
        ])
        lines.orientation = .vertical
        lines.alignment = .width   // the tint runs under the whole line, not only its words
        lines.spacing = Metrics.lineGap
        let out = NSStackView(views: [box, lines])
        out.alignment = .top
        out.edgeInsets = NSEdgeInsets(top: Metrics.lineGap, left: Metrics.inset, bottom: Metrics.lineGap, right: 0)
        return out
    }

    /// The part of `text` that `other` doesn't share: what is left between their common start and end (UTF-16).
    private static func changed(_ text: String, from other: String) -> NSRange {
        let mine = Array(text.utf16), theirs = Array(other.utf16), most = min(mine.count, theirs.count)
        var start = 0, end = 0
        while start < most, mine[start] == theirs[start] { start += 1 }
        while end < most - start, mine[mine.count - 1 - end] == theirs[theirs.count - 1 - end] { end += 1 }
        return NSRange(location: start, length: mine.count - start - end)
    }

    @objc private func toggled(_ box: NSButton) {
        let (fileIndex, matchIndex) = rows[box.tag]
        if let matchIndex {
            if files[fileIndex].chosen.remove(matchIndex) == nil { files[fileIndex].chosen.insert(matchIndex) }
        } else {
            files[fileIndex].chosen = files[fileIndex].chosen.isEmpty ? Set(files[fileIndex].matches.indices) : []
        }
        table.reloadData()
        count()
    }
}
