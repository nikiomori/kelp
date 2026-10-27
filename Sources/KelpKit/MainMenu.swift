import AppKit
import Core
import Sparkle
import WorkbenchKit

/// The menu bar under construction: what's placed so far, and adding commands by id.
@MainActor
final class MenuBuilder {
    let bar = NSMenu()
    let reg: ExtensionRegistry
    /// Commands given a place; the rest go in the menu they name (Tools by default).
    var placed: Set<String> = []
    private let item: (CommandSpec) -> NSMenuItem
    init(reg: ExtensionRegistry, item: @escaping (CommandSpec) -> NSMenuItem) { self.reg = reg; self.item = item }

    func sub(_ title: String) -> NSMenu {
        let mi = bar.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title); bar.setSubmenu(m, for: mi)
        return m
    }

    /// These commands, in order ("-" is a separator); one whose extension is off is left out.
    @discardableResult func add(_ m: NSMenu, _ ids: String...) -> [NSMenuItem] {
        ids.compactMap { id in
            if id == "-" { m.addItem(.separator()); return nil }
            guard let c = reg.command(id) else { return nil }
            placed.insert(id)
            let i = item(c)
            m.addItem(i)
            return i
        }
    }

    /// Only its key: in the menu so the shortcut works, not shown.
    func hide(_ i: NSMenuItem) { i.isHidden = true; i.allowsKeyEquivalentWhenHidden = true }

    /// Every command nothing placed, in the menu it names (after a separator) or in `tools`; Tools goes if it's empty.
    func placeTheRest(in tools: NSMenu) {
        var extended: Set<NSMenu> = []
        for c in reg.all.commands where !placed.contains(c.id) {
            let m = c.menu.flatMap { bar.item(withTitle: $0)?.submenu } ?? tools
            if m !== tools, extended.insert(m).inserted { m.addItem(.separator()) }
            m.addItem(item(c))
        }
        if tools.items.isEmpty { bar.removeItem(at: bar.indexOfItem(withSubmenu: tools)) }
    }
}

extension AppDelegate {
    /// The menu bar is laid out here by command id, like Zed's app menus; titles, keys and actions come from the
    /// registry. Commands it doesn't place (extensions', the other built-ins') go in the menu they name, Tools by default.
    func buildMenu() {
        let b = MenuBuilder(reg: app.extensions, item: item)
        appMenu(b)
        fileMenu(b)
        editMenu(b)
        viewMenu(b)
        selectionMenu(b)
        let tools = b.sub("Tools")   // filled last, with what nothing else placed
        runMenu(b)
        windowMenu(b)
        helpMenu(b)
        b.placeTheRest(in: tools)
        KeyBindings.apply(to: b.bar, app.settings)   // Settings › Keyboard's changes over the defaults (on the English titles)
        Localize.menu(b.bar)           // shown in the user's language
        NSApp.mainMenu = b.bar
    }

    /// Kelp: About, updates, settings, and the standard Services / Hide / Quit.
    private func appMenu(_ b: MenuBuilder) {
        let app = b.sub("Kelp")
        app.addItem(withTitle: "About Kelp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let u = updater {
            app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = u
        }
        b.add(app, "-", "workbench.openSettings", "workbench.openExtensions", "workbench.restartService", "-")
        // The standard application menu: Services, Hide / Hide Others / Show All, Quit.
        let services = NSMenu(title: "Services"); NSApp.servicesMenu = services
        app.setSubmenu(services, for: app.addItem(withTitle: "Services", action: nil, keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Kelp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Kelp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// File: new workspaces, agents and tabs, projects, saving and closing.
    private func fileMenu(_ b: MenuBuilder) {
        let app = self.app
        let file = b.sub("File")
        b.add(file, "workspace.new", "agents.new", "terminal.new", "terminal.tmux")
        let with = NSMenu()
        for a in app.catalog.installed(app.catalog.all) { with.add(a.name) { app.extensions.run("agents.new", ["agent": .string(a.id)]) } }
        with.addItem(.separator())
        for e in b.reg.all.editors {
            with.add(e.title, symbol: e.icon) { e.open(IDEContext.of(app), in: app) }
        }
        file.setSubmenu(with, for: file.addItem(withTitle: "New Tab", action: nil, keyEquivalent: ""))
        b.add(file, "workspace.addProject", "workspace.cloneRepository", "workspace.addRemote", "-", "workspace.revealInFinder")
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { app.worktree(app.workbench.workspaceId)?.path }, prefix: "")
        if !openIn.items.isEmpty { file.setSubmenu(openIn, for: file.addItem(withTitle: "Open Workspace In", action: nil, keyEquivalent: "")) }
        b.add(file, "-", "editor.save", "editor.saveAll", "-", "editor.closeTab", "workspace.close")
    }

    /// Edit: undo, the clipboard, Find, and the editor's commands.
    private func editMenu(_ b: MenuBuilder) {
        let edit = b.sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Find, as in every Mac editor: the panel, next / previous, use selection.
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [("Find…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
                                           ("Find Next", "g", [.command], .next), ("Find Previous", "G", [.command, .shift], .previous),
                                           ("Use Selection for Find", "e", [.command], .setFindString)] {
            let i = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.tag = Int(action.rawValue)
        }
        b.add(find, "files.findInWorkspace")
        edit.setSubmenu(find, for: edit.addItem(withTitle: "Find", action: nil, keyEquivalent: ""))
        b.add(edit, "editor.goToLine", "editor.jumpToDefinition", "editor.sendToAgent", "editor.copyReference", "editor.copyWebLink",
              "-", "editor.fold", "editor.unfold", "editor.unfoldAll")
        let markdown = NSMenu(title: "Markdown")
        b.add(markdown, "markdown.bold", "markdown.italic", "markdown.code", "markdown.link", "-", "markdown.bullets", "markdown.numbered",
              "markdown.tasks", "-", "markdown.cycleView")
        edit.setSubmenu(markdown, for: edit.addItem(withTitle: "Markdown", action: nil, keyEquivalent: ""))
    }

    /// Selection: the code editor's, as VS Code's. After View: a key goes to the first menu item that has it, on or off,
    /// and ⌘D, ⌘[ ⌘] are Split Right and the panes outside the editor (inside, the editor takes them first: EditorBox).
    private func selectionMenu(_ b: MenuBuilder) {
        b.add(b.sub("Selection"), "editor.addNextOccurrence", "editor.selectAllOccurrences", "-", "editor.moveLinesUp", "editor.moveLinesDown",
              "editor.copyLinesUp", "editor.copyLinesDown", "editor.deleteLines", "-", "editor.toggleComment", "editor.indent", "editor.outdent")
    }

    /// View: the sidebar and inspector, panels, text size, panes and tabs.
    private func viewMenu(_ b: MenuBuilder) {
        let app = self.app
        let view = b.sub("View")
        b.add(view, "workbench.toggleSidebar", "workbench.toggleInspector", "workbench.toggleFocusMode")
        for (i, p) in b.reg.all.panels.prefix(9).enumerated() {
            let m = view.add("  " + p.title, symbol: p.icon, key: "\(i + 1)") { app.extensions.run("workbench.showPanel", ["panel": .string(p.id)]) }
            m.keyEquivalentModifierMask = [.command, .option]
        }
        b.placed.insert("workbench.showPanel")
        b.add(view, "-", "view.biggerText")
        // ⌘= enlarges too, as in Ghostty, VS Code and Safari (+ is the shifted =).
        b.hide(view.add("Bigger Text", key: "=") { app.extensions.run("view.biggerText") })
        b.add(view, "view.smallerText", "view.defaultTextSize", "-", "terminal.splitRight", "terminal.splitDown", "agents.sideBySide",
              "view.maximizePane", "view.equalizePanes")
        let panes = NSMenu(title: "Select Pane")
        b.add(panes, "view.nextPane", "view.previousPane", "-", "view.paneLeft", "view.paneRight", "view.paneAbove", "view.paneBelow")
        view.setSubmenu(panes, for: view.addItem(withTitle: "Select Pane", action: nil, keyEquivalent: ""))
        b.add(view, "-", "editor.nextTab", "editor.previousTab")
        for n in 1...9 { b.add(view, "editor.tab.\(n)").forEach { $0.isHidden = n > 3; $0.allowsKeyEquivalentWhenHidden = true } }
        // ⌃Tab / ⌃⇧Tab: the workspace switcher (Window menu); tabs keep ⇧⌘] / ⇧⌘[.
        b.add(view, "-", "workbench.commandPalette", "files.quickOpen", "agents.history", "-")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
    }

    /// Run: the project's commands (ScriptsMenu fills in the rest) and the editor's run / test / format.
    private func runMenu(_ b: MenuBuilder) {
        let runs = b.sub("Run")
        runs.delegate = app.scripts   // the project's other commands go between the separators
        b.add(runs, "scripts.run", "scripts.test", "scripts.stop", "-", "-", "editor.runFile", "editor.testAtCursor", "editor.format", "-", "scripts.edit")
    }

    /// Window: workspaces, the agent needing you, archived workspaces.
    private func windowMenu(_ b: MenuBuilder) {
        let app = self.app
        let win = b.sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        b.add(win, "agents.nextNeedingYou", "agents.usage", "workbench.scratch", "workspace.switch")
        let back = win.add("", key: "\t") { app.extensions.run("workspace.switch", ["by": -1]) }
        back.keyEquivalentModifierMask = [.control, .shift]; b.hide(back)
        b.add(win, "workspace.next", "workspace.previous", "workspace.back", "workspace.forward")
        for n in 1...9 { b.add(win, "workspace.select.\(n)").forEach { $0.isHidden = n > 1; $0.allowsKeyEquivalentWhenHidden = true } }
        win.addItem(.separator())
        let archived = NSMenu(title: "Archived Workspaces"); archived.delegate = archivedMenu
        win.setSubmenu(archived, for: win.addItem(withTitle: "Archived Workspaces", action: nil, keyEquivalent: ""))
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win
    }

    /// Help: macOS puts its menu search here.
    private func helpMenu(_ b: MenuBuilder) {
        let help = b.sub("Help")
        b.add(help, "help.guide", "help.extensionGuide")
        NSApp.helpMenu = help
    }
}
