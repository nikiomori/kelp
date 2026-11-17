import AppKit
import Core
import DesignKit
import KelpKit

/// A server's menu, which depends on where the server comes from. Kelp edits the servers it keeps itself. A server in
/// a single agent's own settings is removed with that agent's command. Other servers come from the account, wait for
/// a sign-in, or came with a plugin or the agent.
extension AddonMenu {
    /// Returns the one agent whose own settings file holds this server, so "Give to All Agents" can copy it from there.
    static func only(_ addon: Addon) -> String? {
        guard addon.kind == .server, addon.source == .yours, addon.origin != Addon.kept,
            addon.agents.count == 1, let agent = addon.agents.first,
            [Session.claudeAgent, Session.codexAgent].contains(agent)
        else { return nil }
        return agent
    }

    /// Whether Kelp can remove the server: it is in Kelp's own file or the project's.
    static func removable(_ addon: Addon) -> Bool {
        addon.kind == .server && (addon.origin == Addon.kept || addon.origin == ".mcp.json")
    }

    func server(_ menu: NSMenu, _ addon: Addon) {
        if addon.signIn || addon.source == .account { return account(menu, addon) }
        if Self.removable(addon) { return kept(menu, addon) }
        if let path = addon.path {
            menu.add(String(localized: "Open \((path as NSString).lastPathComponent)")) { open(path) }
        }
        if let agent = Self.only(addon) { return agentsOwn(menu, addon, agent) }
        separate(menu)
        onOff(menu, addon)
    }

    /// Fills the menu for a server that was added with + or handed on from an agent. Kelp keeps such a server, so Kelp
    /// can edit and remove it.
    private func kept(_ menu: NSMenu, _ addon: Addon) {
        guard let key = addon.key else { return }
        menu.add(String(localized: "Edit…")) { edit(addon, key) }
        copyJSON(menu, addon, key)
        if let path = addon.path {
            menu.add(String(localized: "Open \((path as NSString).lastPathComponent)")) { open(path) }
        }
        separate(menu)
        onOff(menu, addon)
        separate(menu)
        menu.add(String(localized: "Remove…")) {
            confirm(
                String(localized: "Remove “\(addon.name)”?"),
                String(localized: "New chats won’t get this server. Its entry is deleted."),
                action: String(localized: "Remove")
            ) { send(AddonsRemove(worktreeId: worktreeId, key: key)) }
        }
    }

    /// Fills the menu for a server in one agent's own settings. Kelp only reads it there, so removing it runs that
    /// agent's own command in a terminal tab the person sees.
    private func agentsOwn(_ menu: NSMenu, _ addon: Addon, _ agent: String) {
        if let key = addon.key { copyJSON(menu, addon, key) }
        separate(menu)
        let name = AddonGroups.serverName(addon)
        menu.add(String(localized: "Give to All Agents")) {
            send(AddonsAdd(worktreeId: worktreeId, name: name, entry: nil, from: agent))
        }
        onOff(menu, addon)
        separate(menu)
        let (who, command) =
            agent == Session.codexAgent
            ? (String(localized: "Codex"), "codex mcp remove ")
            : (String(localized: "Claude Code"), "claude mcp remove ")
        menu.add(String(localized: "Remove with \(who)…")) {
            confirm(
                String(localized: "Remove “\(addon.name)” from \(who)?"),
                String(localized: "\(who) takes it out of its settings, in a terminal tab here: \(command)\(name)"),
                action: String(localized: "Remove")
            ) { run(command + ShellQuote.word(name), String(localized: "Remove \(name)")) }
        }
    }

    /// Fills the menu for the account's connectors and for servers that wait for a sign-in.
    private func account(_ menu: NSMenu, _ addon: Addon) {
        if addon.signIn {
            let name = AddonGroups.serverName(addon)
            menu.add(String(localized: "Sign In…")) {
                run("claude mcp login " + ShellQuote.word(name), String(localized: "Sign in to \(addon.name)"))
            }
        }
        onOff(menu, addon)
        if addon.signIn {
            separate(menu)
            offAll(menu, AddonGroups.unsigned(items))
        }
        if addon.source == .account {
            separate(menu)
            menu.add(String(localized: "Manage on claude.ai")) { outside("https://claude.ai/settings/connectors") }
        }
    }

    private func copyJSON(_ menu: NSMenu, _ addon: Addon, _ key: String) {
        menu.add(String(localized: "Copy as JSON")) {
            Task {
                guard let entry = await app.call(AddonsEntry(worktreeId: worktreeId, key: key)) else { return }
                copyText(Self.json(AddonGroups.serverName(addon), entry))
            }
        }
    }

    /// Opens the form filled with the entry as its file has it, and saves the result under the same name in the same
    /// file.
    private func edit(_ addon: Addon, _ key: String) {
        let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? String(localized: "This Project")
        let name = AddonGroups.serverName(addon), shared = addon.origin == ".mcp.json"
        Task { [app, worktreeId, done] in
            guard let entry = await app.call(AddonsEntry(worktreeId: worktreeId, key: key)) else { return }
            let sheet = AddonSheet(
                app: app, worktreeId: worktreeId, project: project, items: [],
                editing: (name, Self.json(name, entry), shared))
            guard case .server(_, let changed, _)? = await sheet.ask() else { return }
            await app.call(AddonsAdd(worktreeId: worktreeId, name: name, entry: changed, project: shared))
            done()
        }
    }

    /// Returns the entry as `{"name": {…}}`, the way the agents' files spell it.
    static func json(_ name: String, _ entry: ServerEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return String(decoding: try encoder.encode([name: entry]), as: UTF8.self)
        } catch {
            return ""   // a ServerEntry holds only strings and lists of strings, so it always encodes
        }
    }
}
