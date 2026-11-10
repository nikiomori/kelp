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
        let sheet = CloneSheet(app: app)
        guard sheet.begin(ended: { shown = nil }) else { return }
        shown = sheet
        if let text {
            sheet.field.stringValue = text
            sheet.fill()
            sheet.start()
        }
    }

    private init(app: AppModel) {
        super.init(app: app, width: Metrics.sheetWidth)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where clones go: the last place used, else next to the newest project, else ~/Developer or home.
    private var lastParent: URL {
        if let saved = UserDefaults.standard.string(forKey: "newProject.parent"),
            FileManager.default.fileExists(atPath: saved)
        {
            return URL(fileURLWithPath: saved)
        }
        if let repo = app.repos.last(where: { !Paths.inside($0.path, Paths.root.path) }) {
            return URL(fileURLWithPath: repo.path).deletingLastPathComponent()
        }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : FileManager.default.homeDirectoryForCurrentUser
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Clone a Repository"))
        title.font = .ui(TextSize.body, weight: .semibold)
        field.placeholderString = "https://github.com/owner/repo or git@…"
        field.delegate = self
        dest.delegate = self
        dest.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dest.usesSingleLineMode = true
        dest.lineBreakMode = .byTruncatingHead   // a long path keeps its end in view: the folder it goes into
        fill()
        choose.title = String(localized: "Choose…")
        choose.bezelStyle = .push
        choose.target = self
        choose.action = #selector(pick)
        let row = NSStackView(views: [dest, choose])
        row.spacing = Metrics.gapWide
        let grid = SheetForm.grid([(String(localized: "URL"), field), (String(localized: "Clone into"), row)])
        bar.style = .bar
        bar.isIndeterminate = true
        bar.isHidden = true
        bar.minValue = 0
        bar.maxValue = 100
        status.textColor = .secondaryLabelColor
        status.font = .ui(TextSize.caption)
        status.isHidden = true
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
        let buttons = NSStackView(views: [NSView(), cancel, go])
        buttons.spacing = Metrics.gapWide
        window?.contentView = SheetForm.stack(
            [title, grid, bar, status, buttons], wide: [bar, status, buttons], width: Metrics.sheetWidth)
        window?.initialFirstResponder = field
    }

    func controlTextDidChange(_ n: Notification) {
        if n.object as? NSTextField === dest { destEdited = !dest.stringValue.isEmpty } else { fill() }
    }

    /// "~/Developer/" + the URL's repository name, unless the destination was typed.
    private func fill() {
        guard !destEdited else { return }
        let name = RepoClone.folderName(field.stringValue)
        dest.stringValue =
            (parent.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath
            + (name.isEmpty ? "/" : "")
    }

    /// A folder to clone into, in an open panel: anywhere up or down from the last one, or a new one.
    @objc private func pick() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = parent
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            parent = url
            destEdited = false
            fill()
        }
    }

    /// The typed destination as a full path; one ending in "/" is the folder to go in, named after the repository.
    private var destination: String? {
        let typed = dest.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = (typed as NSString).expandingTildeInPath   // drops a trailing "/": checked on what was typed
        if typed.hasSuffix("/") {
            path = (path as NSString).appendingPathComponent(RepoClone.folderName(field.stringValue))
        }
        return path.hasPrefix("/") ? (path as NSString).standardizingPath : nil
    }

    /// A line git printed while cloning (`event.clone`): shown if it's this sheet's clone.
    static func cloneProgress(id: String?, line: String?) {
        if let sheet = shown, let id, id == sheet.running, let line { sheet.progress(line) }
    }

    /// "Receiving objects:  45% (450/1000)" fills the bar; the line itself says what's happening.
    private func progress(_ line: String) {
        status.isHidden = false
        status.textColor = .secondaryLabelColor
        status.stringValue = line
        if let match = line.firstMatch(of: #/(\d+)%/#), let pct = Double(match.1) {
            bar.isIndeterminate = false
            bar.doubleValue = pct
        }
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
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        guard let path = destination else {
            status.isHidden = false
            status.textColor = .textRed
            status.stringValue = String(localized: "Enter the full path to clone to, like ~/Developer/app.")
            return
        }
        let parent = (path as NSString).deletingLastPathComponent, folder = (path as NSString).lastPathComponent
        let id = UUID().uuidString
        running = id
        busy(true)
        status.isHidden = false
        status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Connecting…")
        Task {
            let result = await app.tryCall(RepoClone(url: text, parent: parent, folder: folder, id: id))
            running = nil
            busy(false)
            if let error = result.error {
                if error == "Clone cancelled." {
                    close()
                    return
                }
                status.textColor = .textRed
                status.stringValue = error
                return
            }
            UserDefaults.standard.set(parent, forKey: "newProject.parent")
            close()
            if let path = result.value?.path { app.workbench.addProject(path: path) }   // on screen
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
