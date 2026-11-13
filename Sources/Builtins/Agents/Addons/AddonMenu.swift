import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A row's own menu, by what the row is: a skill of the person's or the project's, a plugin or one of its skills, a
/// server (Kelp's, an agent's own, the account's), what doesn't work, an instruction file. What can't apply isn't
/// there; what can't be undone comes last.
@MainActor
struct AddonMenu {
    let app: AppModel, worktreeId: String
    /// Everything listed: a plugin's id and folder, and the servers waiting for a sign-in, are read from it.
    let items: [Addon]
    /// The chat the panel shows, if it shows one: Fix with Agent types into it.
    let chat: Session?
    /// After a change: the list read again.
    let done: () -> Void

    func fill(_ menu: NSMenu, _ line: AddonLine) {
        switch line {
        case .item(let addon, _): item(menu, addon)
        case .problem(let addon): problem(menu, addon)
        case .group(let g, _, _, _):
            if let plugin = g.plugin { self.plugin(menu, plugin, key: g.key, off: AddonGroups.isOff(g, items)) }
        case .unsigned(let servers): offAll(menu, servers)
        case .instructions(_, let tidied):
            let tidy = TidyUp(app: app, worktreeId: worktreeId, items: items)
            if tidied == nil {
                menu.add(String(localized: "Tidy Up with"), submenu: tidy.agents())
            } else {
                menu.add(String(localized: "Review Changes")) { tidy.review() }
                menu.add(String(localized: "Keep Changes")) { Task { await tidy.keep(done) } }
                menu.add(String(localized: "Undo…")) { Task { await tidy.undo(done) } }
            }
        case .section: break
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
    }

    private func item(_ menu: NSMenu, _ addon: Addon) {
        switch addon.kind {
        case .instructions:
            locate(menu, addon.path, open: String(localized: "Open"), folder: false)
        case .server: server(menu, addon)
        case .skill where addon.source == .plugin:
            if let path = addon.path { menu.add(String(localized: "Open SKILL.md")) { open(path) } }
            if let name = addon.origin { plugin(menu, name, key: addon.key, off: addon.off) }
        case .skill, .plugin: skill(menu, addon)
        }
    }

    /// A skill in a folder: the person's or the project's can be handed to every agent and trashed.
    private func skill(_ menu: NSMenu, _ addon: Addon) {
        locate(menu, addon.path, open: String(localized: "Open SKILL.md"), folder: true)
        separate(menu)
        onOff(menu, addon)
        guard [.yours, .project].contains(addon.source), let key = addon.key else { return }
        if !addon.agents.contains("claude") || !addon.agents.contains("codex") {
            menu.add(String(localized: "Give to All Agents")) { send(AddonsLink(worktreeId: worktreeId, key: key)) }
        }
        separate(menu)
        menu.add(String(localized: "Move to Trash…")) {
            confirm(
                String(localized: "Move “\(addon.name)” to the Trash?"),
                String(
                    localized:
                        "Agents won’t get this skill any more. Its folder goes to the Trash with the links to it."),
                action: String(localized: "Move to Trash")
            ) { send(AddonsTrash(worktreeId: worktreeId, key: key)) }
        }
    }

    /// A plugin's line, or a skill of it: its switch, its folder, and taking it out with the agent that installed it.
    private func plugin(_ menu: NSMenu, _ name: String, key: String?, off: Bool) {
        separate(menu)
        if let key { onOff(menu, key, off: off) }
        if let folder = AddonGroups.pluginFolder(name, items) {
            menu.add(String(localized: "Reveal in Finder")) { reveal(folder) }
        }
        guard let id = AddonGroups.pluginId(name, items) else { return }
        if id.hasSuffix("@synced") {
            menu.add(String(localized: "Manage on claude.ai")) { outside("https://claude.ai/settings/capabilities") }
            return
        }
        separate(menu)
        menu.add(String(localized: "Uninstall with Claude Code…")) {
            confirm(
                String(localized: "Uninstall “\(name)”?"),
                String(localized: "Claude Code takes it out, in a terminal tab here: claude plugin uninstall \(id)"),
                action: String(localized: "Uninstall")
            ) { run("claude plugin uninstall " + ShellQuote.word(id), String(localized: "Uninstall \(name)")) }
        }
    }

    /// What doesn't work: its whole error, and the chat asked to find out why.
    private func problem(_ menu: NSMenu, _ addon: Addon) {
        let error = addon.error ?? addon.problem ?? ""
        menu.add(String(localized: "Show the Error")) {
            Task { await Self.showError(addon.problem ?? addon.name, error) }
        }
        menu.add(String(localized: "Copy the Error")) { copyText(error) }
        separate(menu)
        if chat != nil {
            menu.add(String(localized: "Fix with Agent")) {
                FileActions(app).sendToAgent(
                    text: String(
                        localized: """
                            The MCP server "\(addon.name)" doesn't start: \(error). Find out why and tell me how to \
                            fix it; don't change my settings without asking.
                            """))
            }
        }
        if let key = addon.key, !addon.off {
            menu.add(String(localized: "Off in This Project")) { set([key], on: false) }
        }
    }

    func offAll(_ menu: NSMenu, _ servers: [Addon]) {
        guard !servers.isEmpty else { return }
        menu.add(String(localized: "Turn Off All \(servers.count) Not Signed In")) {
            set(servers.compactMap(\.key), on: false)
        }
    }

    // MARK: Parts

    /// Open, Reveal in Finder, Copy Path; `folder`: what's revealed is the folder the file is in (a skill's).
    func locate(_ menu: NSMenu, _ path: String?, open title: String, folder: Bool) {
        guard let path else { return }
        menu.add(title) { open(path) }
        let shown = folder ? (path as NSString).deletingLastPathComponent : path
        menu.add(String(localized: "Reveal in Finder")) { reveal(shown) }
        menu.add(String(localized: "Copy Path")) { copyText(path) }
    }

    func onOff(_ menu: NSMenu, _ addon: Addon) {
        if let key = addon.key { onOff(menu, key, off: addon.off) }
    }
    func onOff(_ menu: NSMenu, _ key: String, off: Bool) {
        let title = off ? String(localized: "On in This Project") : String(localized: "Off in This Project")
        menu.add(title) { set([key], on: off) }
    }

    func separate(_ menu: NSMenu) {
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
    }

    func open(_ path: String) { app.workbench.open(TabURI.file(path)) }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func outside(_ address: String) { if let url = URL(string: address) { PreviewLinks.openOutside(url) } }

    /// The project's switches, one after another, then the list again.
    func set(_ keys: [String], on: Bool) {
        Task { [app, worktreeId, done] in
            for key in keys { await app.call(AddonsSet(worktreeId: worktreeId, key: key, on: on)) }
            done()
        }
    }

    func send<M: RPCMethod>(_ method: M) {
        Task { [app, done] in
            await app.call(method)
            done()
        }
    }

    /// An agent's own command, in a terminal tab the person sees: what it does to its files is its own.
    func run(_ command: String, _ title: String) { app.workbench.starter?.run(command: command, title: title) }

    func confirm(_ question: String, _ detail: String, action: String, then: @escaping @MainActor () -> Void) {
        Task {
            if await DesignKit.confirm(question, detail: detail, action: action) { then() }
        }
    }

    /// The whole error, to read and copy.
    static func showError(_ title: String, _ error: String) async {
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: Metrics.alertAccessory, height: Metrics.alertAccessory / 2)
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.string = error
            text.font = .uiMono(TextSize.caption)
            text.isEditable = false
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.addButton(withTitle: String(localized: "Close"))
        if await runSheet(alert) == .alertFirstButtonReturn { copyText(error) }
    }
}
