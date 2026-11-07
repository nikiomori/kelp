import AppKit
import Agents
import Core
import WorkbenchKit

/// What the "+" menu and the empty workspace offer, in one order with one set of names and keys, so the two can't drift:
/// the agents, what opens (a terminal, tmux, what extensions open), what runs.
@MainActor
enum NewTabChoices {
    struct Action {
        let title: String, symbol: String
        let key: KeySpec?
        var help: String?
        let run: @MainActor () -> Void
    }

    /// Agents shown before the rest go behind one item.
    static let shown = 6

    /// The key command `id` has in the menus: settings.json's `keys` over it (`""`: none), else its default, so a key
    /// rebound in Settings › Keyboard reads the same here.
    static func key(_ id: String, _ app: AppModel, default def: String) -> KeySpec? {
        guard let over = KeyBindings.overrides(app.settings)[id] else { return KeySpec(app.extensions.command(id)?.key ?? def) }
        return over.isEmpty ? nil : KeySpec(over)
    }
    /// The default agent's key: New Agent's.
    static func defaultKey(_ app: AppModel) -> KeySpec? { key("agents.new", app, default: "opt+cmd+t") }

    /// The installed agents: the default first, then those in use, then the others by name.
    static func agents(_ app: AppModel) -> [AgentManifest] {
        let def = app.catalog.defaultAgent, started = Set(app.sessions.map(\.agent))
        let rank = { (a: AgentManifest) in (a.id == def ? 0 : 1, started.contains(a.id) ? 0 : 1, a.name.lowercased()) }
        return app.catalog.installed(app.catalog.all).sorted { rank($0) < rank($1) }
    }

    /// A terminal, a tmux session when there is tmux, and what extensions open, in the registry's order.
    static func open(_ app: AppModel, _ w: Worktree?, terminal: @escaping @MainActor () -> Void) -> [Action] {
        let new = key("terminal.new", app, default: "cmd+t")
        var all = [Action(title: String(localized: "Terminal"), symbol: "terminal", key: new, run: terminal)]
        if app.catalog.hasTmux(w) {
            all.append(Action(title: String(localized: "tmux Session…"), symbol: "rectangle.split.3x1", key: nil) { app.quickOpen.showTmux() })
        }
        let ctx = IDEContext.of(app)
        for e in app.extensions.all.editors {
            all.append(Action(title: e.label, symbol: e.icon, key: app.extensions.command(e.id)?.key.flatMap(KeySpec.init)) { e.open(ctx, in: app) })
        }
        return all
    }

    /// What the run chip runs and its list; none while the project offers nothing to run.
    static func run(_ app: AppModel, workspace wid: String) -> [Action] {
        guard let o = app.scripts.offer(wid) else { return [] }
        let choose = key("scripts.choose", app, default: "ctrl+cmd+r"), run = o.guess ? nil : key("scripts.run", app, default: "cmd+r")
        return [Action(title: String(localized: "Run \(o.label)"), symbol: "play", key: run, help: o.command) {
                    Task { await app.scripts.start(choice: o.choice, in: wid) }
                },
                Action(title: String(localized: "Choose What to Run…"), symbol: "list.bullet", key: choose) { app.scripts.choose() }]
    }
}

@MainActor
extension NSMenu {
    /// An action as an item: its symbol shown (macOS 27 hides the rest) and its key beside it.
    @discardableResult
    func add(_ a: NewTabChoices.Action, before: (@MainActor () -> Void)? = nil) -> NSMenuItem {
        let i = add(a.title) { before?(); a.run() }
        i.show(.symbol(a.symbol))
        if let k = a.key { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags }
        i.toolTip = a.help
        return i
    }
}
