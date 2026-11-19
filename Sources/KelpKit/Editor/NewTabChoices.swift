import Agents
import AppKit
import Core
import WorkbenchKit

/// What the "+" menu and the empty workspace offer, in one order with one set of names and keys, so the two can't drift:
/// the agents, what opens (a terminal, tmux, what extensions open), what runs (`ProjectRuns.choices`).
@MainActor
package enum NewTabChoices {
    package struct Action {
        let title: String, symbol: String
        let key: KeySpec?
        var help: String?
        let run: @MainActor () -> Void
        package init(
            title: String, symbol: String, key: KeySpec?, help: String? = nil, run: @escaping @MainActor () -> Void
        ) {
            self.title = title
            self.symbol = symbol
            self.key = key
            self.help = help
            self.run = run
        }
    }

    /// How many agents show before the rest go behind one item.
    static let shown = 6

    /// Returns the key for command `id` in the menus: settings.json's `keys` override it (`""` means none), otherwise
    /// its default, so a key rebound in Settings › Keyboard shows the same here.
    package static func key(_ id: String, _ app: AppModel, default def: String) -> KeySpec? {
        app.extensions.key(id, fallback: def)
    }
    /// The key that starts the default agent: the key of the New Agent command.
    static func defaultKey(_ app: AppModel) -> KeySpec? { key("agents.new", app, default: "opt+cmd+t") }

    /// The agents `worktree` can start: the default first, then those in use, then the others by name.
    static func agents(_ app: AppModel, in worktree: Worktree?) -> [AgentManifest] {
        let def = app.catalog.defaultAgent(in: worktree), started = Set(app.sessions.map(\.agent))
        let rank = { (agent: AgentManifest) in
            (agent.id == def ? 0 : 1, started.contains(agent.id) ? 0 : 1, agent.name.lowercased())
        }
        return app.catalog.startable(in: worktree).sorted { rank($0) < rank($1) }
    }

    /// A terminal, a tmux session when there is tmux, and what extensions open, in the registry's order.
    static func open(_ app: AppModel, _ worktree: Worktree?, terminal: @escaping @MainActor () -> Void) -> [Action] {
        let new = key("terminal.new", app, default: "cmd+t")
        var all = [Action(title: String(localized: "Terminal"), symbol: "terminal", key: new, run: terminal)]
        if app.catalog.hasTmux(worktree) {
            all.append(
                Action(title: String(localized: "tmux Session…"), symbol: "rectangle.split.3x1", key: nil) {
                    app.quickOpen.showTmux()
                })
        }
        let ctx = IDEContext.of(app)
        for editor in app.extensions.all.editors where editor.available?(ctx) ?? true {
            all.append(
                Action(title: editor.label, symbol: editor.icon, key: app.extensions.key(editor.id)) {
                    editor.open(ctx, in: app)
                })
        }
        return all
    }
}

@MainActor
extension NSMenu {
    /// Adds an action as an item, with its symbol shown (macOS 27 hides other items' images) and its key beside it.
    @discardableResult
    func add(_ action: NewTabChoices.Action, before: (@MainActor () -> Void)? = nil) -> NSMenuItem {
        let item = add(action.title) {
            before?()
            action.run()
        }
        item.show(.symbol(action.symbol))
        if let shortcut = action.key {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.mods.flags
        }
        item.toolTip = action.help
        return item
    }
}
