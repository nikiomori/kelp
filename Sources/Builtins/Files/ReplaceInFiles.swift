import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// One file of a replacement: its text as read, the version that was, and which of its matches go through.
struct ReplaceFile {
    let path: String, name: String, text: String, stamp: FileStamp, matches: [ReplaceMatch]
    var chosen: Set<Int>
    var result: String { ReplaceInText.applying(matches.enumerated().filter { chosen.contains($0.offset) }.map(\.element), to: text) }
}

@MainActor
extension FilesPanel {
    /// Replace All: read what the search found, show what would change, write what's chosen. A file with unsaved edits is
    /// left out, as what's on disk isn't what's in its tab.
    func replaceAll() {
        let template = replaceField.stringValue, query = search.stringValue.trimmingCharacters(in: .whitespaces), o = searchOptions
        let names = Array(Set(matches.map(\.path))).sorted(), root = root, app = app
        var options = FindOptions()
        options.matchCase = o.matchCase
        options.wholeWord = o.wholeWord
        options.regex = o.regex
        // By real path: a tab may name its file through a link (/tmp, /private/tmp).
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let edited = Set(app.workbench.editedFiles.compactMap { $0.fileURL.map { real($0.path) } })
        Task { @MainActor in
            var files: [ReplaceFile] = []
            for name in names where !edited.contains(real(root + "/" + name)) {
                guard let r = await app.quiet(FilesRead(path: root + "/" + name)) else { continue }
                do {
                    let text = r.text   // the regex over a big file is off the main thread
                    let plan = try await Task.detached { [options] in try ReplaceInText.plan(text, query: query, options: options, template: template) }.value
                    if plan.isEmpty { continue }
                    files.append(ReplaceFile(path: root + "/" + name, name: name, text: r.text, stamp: r.stamp, matches: plan, chosen: Set(plan.indices)))
                } catch {
                    return Banner.show(String(localized: "Not a valid pattern"), style: .error)
                }
            }
            guard !files.isEmpty else { return Banner.show(String(localized: "Nothing to replace.")) }
            let sheet = ReplaceSheet(files, leftOut: names.count - files.count)
            guard let w = sheet.window, await runSheet(w) == .OK else { return }
            await Self.write(sheet.files, app: app)
            self.runSearch()   // what it found has changed
        }
    }

    /// Over the versions read. One Undo puts every file back, over the versions written.
    static func write(_ files: [ReplaceFile], app: AppModel) async {
        var undo: [FileBatch.Done] = [], refused: [String] = []
        for f in files where !f.chosen.isEmpty {
            if let stamp = await FileBatch.write(f.path, f.result, over: f.stamp, app: app) {
                undo.append(FileBatch.Done(path: f.path, old: f.text, stamp: stamp))
            } else { refused.append(f.name) }
        }
        let note = refused.isEmpty ? "" : " " + String(localized: "Changed since it was read, so left alone: \(refused.joined(separator: ", ")).")
        Banner.show(String(localized: "Replaced in \(undo.count) files.") + note, action: (String(localized: "Undo"), {
            Task { await FileBatch.undoSaying(undo, app: app) }
        }))
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
        rows = files.indices.flatMap { f in [(f, nil)] + files[f].matches.indices.map { (f, Optional($0)) } }
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 460), styleMask: [.titled], backing: .buffered, defer: true)
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
        let left = leftOut > 0 ? String(localized: "\(leftOut) files with unsaved edits or nothing to change are left out.") : ""
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
        let n = files.reduce(0) { $0 + $1.chosen.count }
        go.title = String(localized: "Replace \(n)")
        go.isEnabled = n > 0
    }

    @objc private func cancelled() { finish(.cancel) }
    @objc private func confirmed() { finish(.OK) }
    private func finish(_ r: NSApplication.ModalResponse) { if let window { window.sheetParent?.endSheet(window, returnCode: r) } }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let (f, m) = rows[row]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = row
        guard let m else {
            box.title = files[f].name
            box.state = files[f].chosen.isEmpty ? .off : files[f].chosen.count == files[f].matches.count ? .on : .mixed
            box.font = .ui(12, weight: .semibold)
            return box
        }
        let match = files[f].matches[m]
        box.state = files[f].chosen.contains(m) ? .on : .off
        func line(_ sign: String, _ text: String, _ color: NSColor) -> NSTextField {
            let l = NSTextField(labelWithString: sign + text)
            l.font = .uiMono(11)
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            return l
        }
        let lines = NSStackView(views: [line("\(match.line) − ", match.before, .textRed), line("\(match.line) + ", match.after, .textGreen)])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Metrics.lineGap
        let out = NSStackView(views: [box, lines])
        out.alignment = .top
        out.edgeInsets = NSEdgeInsets(top: Metrics.lineGap, left: Metrics.inset, bottom: Metrics.lineGap, right: 0)
        return out
    }

    @objc private func toggled(_ b: NSButton) {
        let (f, m) = rows[b.tag]
        if let m {
            if files[f].chosen.remove(m) == nil { files[f].chosen.insert(m) }
        } else {
            files[f].chosen = files[f].chosen.isEmpty ? Set(files[f].matches.indices) : []
        }
        table.reloadData()
        count()
    }
}
