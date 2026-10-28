import AppKit
import Core
import DesignKit

/// Remote projects as this app's home keeps them (KELP_HOME/remote): which folders stand for one on a host.
extension RemoteHost {
    package static func of(_ dir: String) -> RemoteHost? { Remotes(home: Paths.root).of(dir) }
    package static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? { Remotes(home: Paths.root).containing(path) }
}

/// Open a project over SSH in two steps: connect to the host (ssh's own reason if Kelp can't), then pick the folder
/// there from a list, as an open panel does (double-click goes in, repositories are marked). Open takes the selected
/// folder, else the one listed; one that isn't in a repository yet gets `git init` first, and the button says so.
@MainActor
final class RemoteSheet: SheetController, NSComboBoxDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The host, as after `ssh` (the hosts in ~/.ssh/config to pick from).
    private let host = NSComboBox()
    /// The folder listed; a path typed here is gone to on Return.
    private let path = NSTextField()
    private let table = NSTableView(), scroll = NSScrollView()
    private let grid: NSGridView
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let go = NSButton(), cancel = NSButton()
    private var rows: [RemoteListFolders.Folder] = []
    /// The host and folder listed (and whether it's in a repository): nil until connected, and again once the host is edited.
    private var listed: (host: String, path: String, repo: Bool)?
    private static var shown: RemoteSheet?

    /// `start`: "host" or "host:/path", connected to at once (the snapshot dev aid; a background app's sheet gets no keys).
    static func show(_ app: AppModel, start text: String? = nil) {
        let s = RemoteSheet(app: app)
        guard s.begin(ended: { shown = nil }) else { return }
        shown = s
        if let text {
            let hp = text.split(separator: ":", maxSplits: 1).map(String.init)
            s.host.stringValue = hp[0]; s.list(hp[0], hp.count > 1 ? hp[1] : "~")
        }
    }

    private init(app: AppModel) {
        grid = NSGridView(views: [[NSTextField(labelWithString: String(localized: "Host:")), host],
                                  [NSTextField(labelWithString: String(localized: "Folder:")), path]])
        super.init(app: app, width: 480)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Open a Project over SSH")); title.font = .ui(13, weight: .semibold)
        host.addItems(withObjectValues: Self.sshHosts()); host.placeholderString = String(localized: "user@server or a Host from ~/.ssh/config")
        host.completes = true; host.delegate = self
        host.stringValue = UserDefaults.standard.string(forKey: "remote.host") ?? ""
        for f in [host, path] as [NSView] { f.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        // The fields don't move when the folder row and the list come and go.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        grid.column(at: 0).width = (0..<2).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width }.max() ?? 0
        let column = NSTableColumn(identifier: .init("folder")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self; table.doubleAction = #selector(enter)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let note = NSTextField(wrappingLabelWithString: String(localized: "Agents and terminals run there, and git too, over one SSH connection. ")
                               + String(localized: "The agents you use must be installed on that machine. Files open read-only."))
        for t in [note, status] {
            t.textColor = .secondaryLabelColor
            t.font = .ui(11)
            t.preferredMaxLayoutWidth = 430
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        go.bezelStyle = .push
        go.keyEquivalent = "\r"
        go.target = self
        go.action = #selector(goPressed)
        cancel.title = String(localized: "Cancel")
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(close)
        let buttons = NSStackView(views: [spinner, NSView(), cancel, go]); buttons.spacing = 8
        let stack = NSStackView(views: [title, grid, scroll, note, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window?.contentView = stack
        window?.initialFirstResponder = host
        say(nil); update()
    }

    /// Before connecting only the host shows, and the button connects; after, the folder and its list, and it opens.
    private func update() {
        let on = listed != nil
        grid.row(at: 1).isHidden = !on; scroll.isHidden = !on
        go.title = !on ? String(localized: "Connect") : target?.repo == false ? String(localized: "Initialize Git and Open") : String(localized: "Open")
    }

    /// What Open opens: the selected folder, else the one listed.
    private var target: (path: String, repo: Bool)? {
        guard let l = listed else { return nil }
        let r = table.selectedRow
        guard rows.indices.contains(r), rows[r].name != ".." else { return (l.path, l.repo) }
        return (Self.join(l.path, rows[r].name), l.repo || rows[r].git)
    }

    func tableViewSelectionDidChange(_ n: Notification) { update() }

    func controlTextDidChange(_ n: Notification) { if n.object as? NSComboBox === host { hostEdited() } }
    func comboBoxSelectionDidChange(_ n: Notification) { hostEdited() }
    private func hostEdited() {
        guard listed != nil else { return }
        listed = nil
        rows = []
        table.reloadData()
        update()
    }

    @objc private func goPressed() {
        let h = host.stringValue.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { NSSound.beep(); return }
        guard let l = listed, l.host == h else { list(h, "~"); return }
        let typed = path.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, typed != l.path { list(h, typed); return }   // a path typed: go there first
        if let t = target { open(h, t.path, init: !t.repo) }
    }

    @objc private func enter() {
        guard let l = listed, rows.indices.contains(table.clickedRow) else { return }
        let f = rows[table.clickedRow]
        list(l.host, f.name == ".." ? (l.path as NSString).deletingLastPathComponent : Self.join(l.path, f.name))
    }

    private func list(_ h: String, _ p: String) {
        busy(true); say(listed == nil ? String(localized: "Connecting…") : nil)
        Task {
            let r = await app.tryCall(RemoteListFolders(host: h, path: p))
            busy(false)
            guard let v = r.value else { say(r.error, error: true); return }
            listed = (h, v.path, v.repo)
            path.stringValue = v.path
            say(nil)
            rows = (v.path == "/" ? [] : [.init(name: "..", git: false)]) + v.folders
            table.reloadData(); update()
            window?.makeFirstResponder(table)
        }
    }

    private func open(_ h: String, _ p: String, init: Bool) {
        busy(true); say(String(localized: "Opening…"))
        Task {
            let r = await app.tryCall(RepoAddRemote(host: h, path: p, init: `init`))
            busy(false)
            if let e = r.error { say(e, error: true); return }
            UserDefaults.standard.set(h, forKey: "remote.host")
            close()
            await app.refresh()
            if let rid = r.value?.id, let repo = app.repo(rid), let w = app.workspaces(of: repo).first {
                app.workbench.show(workspace: w.id)
            }
        }
    }

    private static func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

    private func say(_ text: String?, error: Bool = false) {
        status.isHidden = text == nil; status.stringValue = text ?? ""
        status.textColor = error ? .textRed : .secondaryLabelColor
    }

    private func busy(_ on: Bool) {
        for c in [host, path, table, go] as [NSControl] { c.isEnabled = !on }
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// The `Host` names in ~/.ssh/config (patterns left out).
    static func sshHosts() -> [String] {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard w.first?.lowercased() == "host" else { return [] }
            return w.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }

    // MARK: list

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let f = rows[row], up = f.name == ".."
        let icon = NSImageView(image: .symbol(up ? "arrow.turn.left.up" : f.git ? "arrow.triangle.branch" : "folder"))
        icon.contentTintColor = f.git ? .controlAccentColor : .secondaryLabelColor
        let name = NSTextField(labelWithString: up ? String(localized: "Enclosing Folder") : f.name); name.lineBreakMode = .byTruncatingMiddle
        if up { name.textColor = .secondaryLabelColor }
        let cell = NSStackView(views: [icon, name]); cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return cell
    }
}
