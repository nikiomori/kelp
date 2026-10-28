import AppKit
import Core
import DesignKit

/// Clone a repository by URL, in a sheet that does the work in place: git's progress, its error in the sheet, and
/// Cancel stops it and removes the half-made folder.
@MainActor
final class CloneSheet: SheetController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let dest = NSTextField(), choose = NSButton()
    /// The folder the destination goes in until one is typed; the name in it follows the URL until it's typed over.
    private lazy var parent = lastParent
    private var destEdited = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let go = NSButton(), cancel = NSButton()
    private var running: String?
    private static var shown: CloneSheet?

    /// `start`: filled in and begun at once (the snapshot dev aid; a background app's sheet gets no keys).
    static func show(_ app: AppModel, start text: String? = nil) {
        let s = CloneSheet(app: app)
        guard s.begin(ended: { shown = nil }) else { return }
        shown = s
        if let text {
            s.field.stringValue = text
            s.fill()
            s.start()
        }
    }

    private init(app: AppModel) {
        super.init(app: app, width: 480)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where clones go: the last place used, else next to the newest project, else ~/Developer or home.
    private var lastParent: URL {
        if let s = UserDefaults.standard.string(forKey: "newProject.parent"), FileManager.default.fileExists(atPath: s) { return URL(fileURLWithPath: s) }
        if let r = app.repos.last(where: { !$0.path.hasPrefix(Paths.root.path) }) { return URL(fileURLWithPath: r.path).deletingLastPathComponent() }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : FileManager.default.homeDirectoryForCurrentUser
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Clone a Repository"))
        title.font = .boldSystemFont(ofSize: 13)
        field.placeholderString = "https://github.com/owner/repo or git@…"
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true; field.delegate = self
        dest.delegate = self
        dest.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fill()
        choose.title = String(localized: "Choose…")
        choose.bezelStyle = .push
        choose.target = self
        choose.action = #selector(pick)
        let row = NSStackView(views: [dest, choose]); row.spacing = 8
        let grid = NSGridView(views: [[NSTextField(labelWithString: String(localized: "URL:")), field],
                                      [NSTextField(labelWithString: String(localized: "Clone into:")), row]])
        row.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        bar.style = .bar
        bar.isIndeterminate = true
        bar.isHidden = true
        bar.minValue = 0
        bar.maxValue = 100
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.isHidden = true
        status.preferredMaxLayoutWidth = 430
        go.title = String(localized: "Clone")
        go.bezelStyle = .push
        go.keyEquivalent = "\r"
        go.target = self
        go.action = #selector(start)
        cancel.title = String(localized: "Cancel")
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(stop)
        let buttons = NSStackView(views: [NSView(), cancel, go]); buttons.spacing = 8
        let stack = NSStackView(views: [title, grid, bar, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [bar, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window?.contentView = stack
        window?.initialFirstResponder = field
    }

    func controlTextDidChange(_ n: Notification) {
        if n.object as? NSTextField === dest { destEdited = !dest.stringValue.isEmpty } else { fill() }
    }

    /// "~/Developer/" + the URL's repository name, unless the destination was typed.
    private func fill() {
        guard !destEdited else { return }
        let name = RepoClone.folderName(field.stringValue)
        dest.stringValue = (parent.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath + (name.isEmpty ? "/" : "")
    }

    /// A folder to clone into, in an open panel: anywhere up or down from the last one, or a new one.
    @objc private func pick() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = String(localized: "Choose"); p.directoryURL = parent
        p.beginSheetModal(for: w) { [self] r in
            guard r == .OK, let u = p.url else { return }
            parent = u
            destEdited = false
            fill()
        }
    }

    /// The typed destination as a full path; one ending in "/" is the folder to go in, named after the repository.
    private var destination: String? {
        let typed = dest.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = (typed as NSString).expandingTildeInPath   // drops a trailing "/": checked on what was typed
        if typed.hasSuffix("/") { p = (p as NSString).appendingPathComponent(RepoClone.folderName(field.stringValue)) }
        return p.hasPrefix("/") ? (p as NSString).standardizingPath : nil
    }

    /// A line git printed while cloning (`event.clone`): shown if it's this sheet's clone.
    static func cloneProgress(id: String?, line: String?) {
        if let s = shown, let id, id == s.running, let line { s.progress(line) }
    }

    /// "Receiving objects:  45% (450/1000)" fills the bar; the line itself says what's happening.
    private func progress(_ line: String) {
        status.isHidden = false
        status.textColor = .secondaryLabelColor
        status.stringValue = line
        if let m = line.firstMatch(of: #/(\d+)%/#), let pct = Double(m.1) { bar.isIndeterminate = false; bar.doubleValue = pct }
    }

    private func busy(_ on: Bool) {
        field.isEnabled = !on
        dest.isEnabled = !on
        choose.isEnabled = !on
        go.isEnabled = !on
        bar.isHidden = !on
        if on {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            bar.stopAnimation(nil)
        }
    }

    @objc private func start() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        guard let path = destination else {
            status.isHidden = false; status.textColor = .textRed
            status.stringValue = String(localized: "Enter the full path to clone to, like ~/Developer/app."); return
        }
        let parent = (path as NSString).deletingLastPathComponent, folder = (path as NSString).lastPathComponent
        let id = UUID().uuidString
        running = id; busy(true)
        status.isHidden = false; status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Connecting…")
        Task {
            let r = await app.tryCall(RepoClone(url: text, parent: parent, folder: folder, id: id))
            running = nil; busy(false)
            if let e = r.error {
                if e == "Clone cancelled." { close(); return }
                status.textColor = .textRed
                status.stringValue = e
                return
            }
            UserDefaults.standard.set(parent, forKey: "newProject.parent")
            close()
            if let path = r.value?.path { app.workbench.addProject(path: path) }   // on screen
        }
    }

    @objc private func stop() {
        if let id = running {
            status.stringValue = String(localized: "Cancelling…")
            Task { await app.call(RepoCloneCancel(id: id)) }
            return
        }
        close()
    }
}
