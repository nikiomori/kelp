import AppKit
import Core
import DesignKit

/// Remote projects as this app's home keeps them (KELP_HOME/remote): which folders stand for one on a host.
extension RemoteHost {
    /// Asked for every row of the sidebar: a folder outside remote/ is answered without looking.
    package static func of(_ dir: String) -> RemoteHost? {
        dir.contains("/remote/") ? Remotes(home: Paths.root).of(dir) : nil
    }
    package static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        Remotes(home: Paths.root).containing(path)
    }
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
        let sheet = RemoteSheet(app: app)
        guard sheet.begin(ended: { shown = nil }) else { return }
        shown = sheet
        if let text {
            let hp = text.split(separator: ":", maxSplits: 1).map(String.init)
            sheet.host.stringValue = hp[0]
            sheet.list(hp[0], hp.count > 1 ? hp[1] : "~")
        }
    }

    private init(app: AppModel) {
        grid = SheetForm.grid([(String(localized: "Host"), host), (String(localized: "Folder"), path)])
        super.init(app: app, width: Metrics.sheetWidth)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Open a Project over SSH"))
        title.font = .ui(13, weight: .semibold)
        Task { [host] in   // ~/.ssh/config read off the main thread
            host.addItems(withObjectValues: await Task.detached { Self.sshHosts() }.value)
        }
        host.placeholderString = String(localized: "user@server or a Host from ~/.ssh/config")
        host.completes = true
        host.delegate = self
        host.stringValue = UserDefaults.standard.string(forKey: "remote.host") ?? ""
        grid.rowAlignment = .none
        grid.yPlacement = .center   // a combo box has no first baseline for the grid to line its label up with
        let column = NSTableColumn(identifier: .init("folder"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(enter)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let note = NSTextField(
            wrappingLabelWithString: String(
                localized: "Agents and terminals run there, and git too, over one SSH connection. ")
                + String(localized: "The agents you use must be installed on that machine. Files open read-only."))
        for t in [note, status] {
            t.textColor = .secondaryLabelColor
            t.font = .ui(11)
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
        let buttons = NSStackView(views: [spinner, NSView(), cancel, go])
        buttons.spacing = Metrics.gapWide
        window?.contentView = SheetForm.stack(
            [title, grid, scroll, note, status, buttons], wide: [scroll, note, status, buttons],
            width: Metrics.sheetWidth)
        window?.initialFirstResponder = host
        say(nil)
        update()
    }

    /// Before connecting only the host shows, and the button connects; after, the folder and its list, and it opens.
    private func update() {
        let on = listed != nil
        grid.row(at: 1).isHidden = !on
        scroll.isHidden = !on
        go.title =
            !on
            ? String(localized: "Connect")
            : target?.repo == false ? String(localized: "Initialize Git and Open") : String(localized: "Open")
    }

    /// What Open opens: the selected folder, else the one listed.
    private var target: (path: String, repo: Bool)? {
        guard let current = listed else { return nil }
        let row = table.selectedRow
        guard rows.indices.contains(row), rows[row].name != ".." else { return (current.path, current.repo) }
        return (Self.join(current.path, rows[row].name), current.repo || rows[row].git)
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
        let hostName = host.stringValue.trimmingCharacters(in: .whitespaces)
        guard !hostName.isEmpty else {
            NSSound.beep()
            return
        }
        guard let current = listed, current.host == hostName else {
            list(hostName, "~")
            return
        }
        let typed = path.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, typed != current.path {
            list(hostName, typed)
            return
        }   // a path typed: go there first
        if let chosen = target { open(hostName, chosen.path, init: !chosen.repo) }
    }

    @objc private func enter() {
        guard let current = listed, rows.indices.contains(table.clickedRow) else { return }
        let folder = rows[table.clickedRow]
        list(
            current.host,
            folder.name == ".."
                ? (current.path as NSString).deletingLastPathComponent : Self.join(current.path, folder.name))
    }

    private func list(_ hostName: String, _ folderPath: String) {
        busy(true)
        say(listed == nil ? String(localized: "Connecting…") : nil)
        Task {
            let result = await app.tryCall(RemoteListFolders(host: hostName, path: folderPath))
            busy(false)
            guard let listing = result.value else {
                say(result.error, error: true)
                return
            }
            listed = (hostName, listing.path, listing.repo)
            path.stringValue = listing.path
            say(nil)
            rows = (listing.path == "/" ? [] : [.init(name: "..", git: false)]) + listing.folders
            table.reloadData()
            update()
            window?.makeFirstResponder(table)
        }
    }

    private func open(_ hostName: String, _ folderPath: String, init: Bool) {
        busy(true)
        say(String(localized: "Opening…"))
        Task {
            let result = await app.tryCall(RepoAddRemote(host: hostName, path: folderPath, init: `init`))
            busy(false)
            if let error = result.error {
                say(error, error: true)
                return
            }
            UserDefaults.standard.set(hostName, forKey: "remote.host")
            close()
            if let rid = result.value?.id, let repo = app.repo(rid), let workspace = app.workspaces(of: repo).first {
                app.workbench.show(workspace: workspace.id)
            }
        }
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func say(_ text: String?, error: Bool = false) {
        status.isHidden = text == nil
        status.stringValue = text ?? ""
        status.textColor = error ? .textRed : .secondaryLabelColor
    }

    private func busy(_ on: Bool) {
        for c in [host, path, table, go] as [NSControl] { c.isEnabled = !on }
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// The `Host` names in ~/.ssh/config (patterns left out).
    nonisolated static func sshHosts() -> [String] {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }

    // MARK: list

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let folder = rows[row], up = folder.name == ".."
        let icon = NSImageView(
            image: .symbol(up ? "arrow.turn.left.up" : folder.git ? "arrow.triangle.branch" : "folder"))
        icon.contentTintColor = folder.git ? .controlAccentColor : .secondaryLabelColor
        let name = NSTextField(labelWithString: up ? String(localized: "Enclosing Folder") : folder.name)
        name.lineBreakMode = .byTruncatingMiddle
        if up { name.textColor = .secondaryLabelColor }
        let cell = NSStackView(views: [icon, name])
        cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return cell
    }
}
