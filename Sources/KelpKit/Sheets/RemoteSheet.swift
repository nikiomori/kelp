import AppKit
import Core
import DesignKit

/// Remote projects as this app's home keeps them (KELP_HOME/remote), which says which folders stand for a project on a
/// host.
extension RemoteHost {
    /// Returns the host a folder stands for. Every sidebar row asks, so a folder outside remote/ is answered without
    /// looking.
    package static func of(_ dir: String) -> RemoteHost? {
        dir.contains("/remote/") ? Remotes(home: Paths.root).of(dir) : nil
    }
}

/// Opens a project over SSH in two steps. First it connects to the host (showing ssh's own reason if Kelp can't), then
/// the user picks the folder there from a list, as in an open panel (double-click goes in, repositories are marked).
/// Open takes the selected folder, else the one listed. A folder that isn't in a repository yet gets `git init` first,
/// and the button says so.
@MainActor
final class RemoteSheet: SheetController, NSComboBoxDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The host, written as after `ssh`, with the hosts in ~/.ssh/config to pick from.
    private let host = NSComboBox()
    /// The folder listed. Return goes to a path typed here.
    private let path = NSTextField()
    private let table = NSTableView(), scroll = NSScrollView()
    private let grid: NSGridView
    private let spinner = NSProgressIndicator()
    private lazy var go = NSButton(title: "", target: self, action: #selector(goPressed))
    /// Once connected, the button is as wide as "Initialize Git and Open", so Cancel holds still as the selection
    /// moves between repositories and plain folders.
    private lazy var openWidth = go.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.width(of: go))
    private lazy var cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(close))
    private var rows: [RemoteListFolders.Folder] = []
    /// The host and folder listed, and whether the folder is in a repository. It is nil until connected, and again once
    /// the host is edited.
    private var listed: (host: String, path: String, repo: Bool)?
    private static var shown: RemoteSheet?

    /// Shows the sheet. With `start` ("host" or "host:/path"), it connects at once (for the snapshot dev aid, because a
    /// background app's sheet gets no keys).
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
        title.font = .ui(TextSize.body, weight: .semibold)
        Task { [host] in   // reads ~/.ssh/config off the main thread
            host.addItems(withObjectValues: await Task.detached { RemoteHost.configHosts() }.value)
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
                + String(localized: "The agents you use must be installed on that machine."))
        note.textColor = .secondaryLabelColor
        note.font = .ui(TextSize.caption)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        go.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [spinner, NSView(), cancel, go])
        buttons.spacing = Metrics.gapWide
        window?.contentView = SheetForm.stack(
            [title, grid, scroll, note, status, buttons], wide: [scroll, note, status, buttons],
            width: Metrics.sheetWidth)
        window?.initialFirstResponder = host
        say(nil)
        update()
    }

    /// Before connecting, only the host shows and the button connects. After connecting, the folder and its list show,
    /// and the button opens.
    private func update() {
        let on = listed != nil
        grid.row(at: 1).isHidden = !on
        scroll.isHidden = !on
        SheetForm.fit(window)   // the folder and its list come and go smoothly
        openWidth.isActive = on
        go.title =
            !on
            ? String(localized: "Connect")
            : target?.repo == false ? String(localized: "Initialize Git and Open") : String(localized: "Open")
    }

    /// The folder Open opens: the selected one, else the one listed.
    private var target: (path: String, repo: Bool)? {
        guard let current = listed else { return nil }
        let row = table.selectedRow
        guard rows.indices.contains(row), rows[row].name != ".." else { return (current.path, current.repo) }
        return (Self.join(current.path, rows[row].name), current.repo || rows[row].git)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { update() }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === host { hostEdited() }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) { hostEdited() }
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
        }   // a path was typed, so go there first
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
                // For a host never connected to, ask to trust its key, as ssh's "yes" does, then connect again.
                if result.error?.contains("Host key verification failed") == true, await trust(hostName) {
                    return list(hostName, folderPath)
                }
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

    /// Asks whether to trust the key `hostName` presents, showing the key. Returns true when it is trusted.
    private func trust(_ hostName: String) async -> Bool {
        guard let key = await app.quiet(RemoteHostKey(host: hostName)) ?? nil,
            await confirm(
                String(localized: "Trust \(hostName)?"),
                detail: String(
                    localized:
                        "Kelp hasn’t connected to it before. Its key is \(key.fingerprint) (\(key.kind)): trust it only if that’s the key you expect."
                ),
                action: String(localized: "Trust"))
        else { return false }
        return await app.call(RemoteTrustHost(host: hostName, fingerprint: key.fingerprint)) != nil
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

    private static func width(of button: NSButton) -> CGFloat {
        let titles = [String(localized: "Open"), String(localized: "Initialize Git and Open")]
        return titles.map { title in
            button.title = title
            return button.fittingSize.width
        }.max() ?? 0
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func busy(_ on: Bool) {
        for c in [host, path, table, go] as [NSControl] { c.isEnabled = !on }
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: list

    func numberOfRows(in table: NSTableView) -> Int { rows.count }

    func tableView(_ table: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let folder = rows[row], up = folder.name == ".."
        let icon = NSImageView(
            image: .symbol(up ? "arrow.turn.left.up" : folder.git ? "arrow.triangle.branch" : "folder"))
        // Grey for every row: the branch symbol already tells a repository from a folder, so it needs no colour.
        icon.symbolConfiguration = .chrome(Metrics.iconPoint)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: up ? String(localized: "Enclosing Folder") : folder.name)
        name.font = .ui(TextSize.body)
        name.lineBreakMode = .byTruncatingMiddle
        if up { name.textColor = .secondaryLabelColor }
        let cell = NSStackView(views: [icon, name])
        cell.spacing = Metrics.gap
        cell.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gapTight, bottom: 0, right: Metrics.gapTight)
        icon.widthAnchor.constraint(equalToConstant: TextSize.of(Metrics.appIcon)).isActive = true
        return cell
    }
}
