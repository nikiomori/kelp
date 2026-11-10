import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// One file of a replacement: its text as read, the version that was, and which of its matches go through.
struct ReplaceFile {
    let path: String, name: String, text: String, stamp: FileStamp, matches: [ReplaceMatch]
    var chosen: Set<Int>
    var result: String {
        ReplaceInText.applying(matches.enumerated().filter { chosen.contains($0.offset) }.map(\.element), to: text)
    }
}

@MainActor
extension FilesPanel {
    /// Replace All: read what the search found, show what would change, write what's chosen. A file with unsaved edits is
    /// left out, as what's on disk isn't what's in its tab.
    func replaceAll() {
        let template = replaceField.stringValue, query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let names = Array(Set(results.matches.map(\.path))).sorted(), root = root, app = app
        var options = FindOptions()
        options.matchCase = searchOptions.matchCase
        options.wholeWord = searchOptions.wholeWord
        options.regex = searchOptions.regex
        // By real path: a tab may name its file through a link (/tmp, /private/tmp).
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let edited = Set(app.workbench.editedFiles.compactMap { $0.fileURL.map { real($0.path) } })
        Task { @MainActor in
            var files: [ReplaceFile] = []
            for name in names where !edited.contains(real(root + "/" + name)) {
                guard let contents = await app.quiet(FilesRead(path: root + "/" + name)) else { continue }
                do {
                    let text = contents.text   // the regex over a big file is off the main thread
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
                    return Banner.show(String(localized: "Not a valid pattern"), style: .error)
                }
            }
            guard !files.isEmpty else { return Banner.show(String(localized: "Nothing to replace.")) }
            let sheet = ReplaceSheet(files, leftOut: names.count - files.count)
            guard let window = sheet.window, await runSheet(window) == .OK else { return }
            await Self.write(sheet.files, app: app)
            self.runSearch()   // what it found has changed
        }
    }

    /// Over the versions read. One Undo puts every file back, over the versions written.
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

/// What a replacement would change, file by file, each file and each match with a box.
@MainActor
final class ReplaceSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var files: [ReplaceFile]
    let window: NSWindow?
    private let table = NSTableView()
    private let go = NSButton(title: "", target: nil, action: nil)
    /// The rows: a file, or a match of one.
    private let rows: [(file: Int, match: Int?)]
    private static let width: CGFloat = 640   // wider than a form: the lines of code it lists

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
        note.font = .ui(11)
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
            box.font = .ui(12, weight: .semibold)
            return box
        }
        let match = files[fileIndex].matches[matchIndex]
        box.state = files[fileIndex].chosen.contains(matchIndex) ? .on : .off
        func line(_ sign: String, _ text: String, _ color: NSColor) -> NSTextField {
            let label = NSTextField(labelWithString: sign + text)
            label.font = .uiMono(11)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        let lines = NSStackView(views: [
            line("\(match.line) − ", match.before, .textRed), line("\(match.line) + ", match.after, .textGreen)
        ])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Metrics.lineGap
        let out = NSStackView(views: [box, lines])
        out.alignment = .top
        out.edgeInsets = NSEdgeInsets(top: Metrics.lineGap, left: Metrics.inset, bottom: Metrics.lineGap, right: 0)
        return out
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
