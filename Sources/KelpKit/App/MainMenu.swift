import AppKit
import Core
import DesignKit
import Sparkle

/// Builds the menu bar. It holds what's placed so far and adds commands by id.
@MainActor
final class MenuBuilder {
    let bar = NSMenu()
    let reg: ExtensionRegistry
    /// Commands already given a place. The rest go in the menu they name (Tools by default).
    var placed: Set<String> = []
    private let item: (CommandSpec) -> NSMenuItem
    init(reg: ExtensionRegistry, item: @escaping (CommandSpec) -> NSMenuItem) {
        self.reg = reg
        self.item = item
    }

    func sub(_ title: String) -> NSMenu {
        let mi = bar.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        bar.setSubmenu(menu, for: mi)
        return menu
    }

    /// Adds these commands in order ("-" is a separator). A command whose extension is off is left out.
    @discardableResult func add(_ menu: NSMenu, _ ids: String...) -> [NSMenuItem] {
        ids.compactMap { id in
            if id == "-" {
                menu.addItem(.separator())
                return nil
            }
            guard let command = reg.command(id) else { return nil }
            placed.insert(id)
            let menuItem = item(command)
            menu.addItem(menuItem)
            return menuItem
        }
    }

    /// Hides a menu item but keeps its key, so the shortcut works without the item showing.
    func hide(_ menuItem: NSMenuItem) {
        menuItem.isHidden = true
        menuItem.allowsKeyEquivalentWhenHidden = true
    }

    /// Puts every command not yet placed in the menu it names (after a separator) or in `tools`. Tools is removed if
    /// it ends up empty.
    func placeTheRest(in tools: NSMenu) {
        var extended: Set<NSMenu> = []
        for c in reg.all.commands where !placed.contains(c.id) {
            let menu = c.menu.flatMap { bar.item(withTitle: $0)?.submenu } ?? tools
            if menu !== tools, extended.insert(menu).inserted { menu.addItem(.separator()) }
            menu.addItem(item(c))
        }
        if tools.items.isEmpty { bar.removeItem(at: bar.indexOfItem(withSubmenu: tools)) }
    }
}

extension AppDelegate {
    /// Lays out the menu bar by command id, like Zed's app menus. Titles, keys and actions come from the registry.
    /// Commands not placed here (extensions', the other built-ins') go in the menu they name, Tools by default.
    func buildMenu() {
        let builder = MenuBuilder(reg: app.extensions, item: item)
        appMenu(builder)
        fileMenu(builder)
        editMenu(builder)
        viewMenu(builder)
        selectionMenu(builder)
        let tools = builder.sub("Tools")   // filled last, with the commands nothing else placed
        runMenu(builder)
        windowMenu(builder)
        helpMenu(builder)
        builder.placeTheRest(in: tools)
        KeyBindings.apply(to: builder.bar, app.settings)   // Settings › Keyboard changes, matched on English titles
        Localize.menu(builder.bar)   // shown in the user's language
        NSApp.mainMenu = builder.bar
    }

    /// Builds the Kelp menu: About, updates, settings, and the standard Services / Hide / Quit.
    private func appMenu(_ menuBuilder: MenuBuilder) {
        let app = menuBuilder.sub("Kelp")
        app.addItem(
            withTitle: "About Kelp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        if let ready = self.app.updates.ready {
            let model = self.app
            app.add(String(localized: "Update Kelp to \(ready.version)")) {
                Task { await model.updates.install(model) }
            }
        } else if let controller = updater {
            app.addItem(
                withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            ).target = controller
        }
        menuBuilder.add(app, "-", "workbench.openSettings", "workbench.openExtensions", "workbench.restartService", "-")
        // The standard application menu: Services, Hide / Hide Others / Show All, Quit.
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        app.add("Services", submenu: services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Kelp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        .keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Kelp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Builds the File menu: new workspaces, agents and tabs, projects, saving and closing, and what the chat, the
    /// group and the project in front can do.
    private func fileMenu(_ menuBuilder: MenuBuilder) {
        let app = self.app
        let file = menuBuilder.sub("File")
        menuBuilder.add(
            file, "workspace.new", "workspace.newChatInGroup", "workspace.newGroup", "workspace.newBranch",
            "workspace.newBranchAsking",
            "agents.new", "terminal.new", "terminal.tmux")
        let with = NSMenu()
        let alternates = NSMenuItem.noteColumn(app.catalog.installed.map { NSMenu.inNewGroup($0.name) })
        for a in app.catalog.installed {
            let item = with.add(a.name) { app.extensions.run("agents.new", ["agent": .string(a.id)]) }
            with.addNewGroupAlternate(of: item, agent: a.name, column: alternates) {
                app.workbench.newChatInGroup(agent: a.id)
            }
        }
        with.addItem(.separator())
        for e in menuBuilder.reg.all.editors {
            with.add(e.title, symbol: e.icon) { e.open(IDEContext.of(app), in: app) }
        }
        file.add("New Tab", submenu: with)
        menuBuilder.add(
            file, "workspace.addProject", "workspace.cloneRepository", "workspace.addRemote", "machines.new", "-",
            "workspace.revealInFinder", "workspace.copyPath")
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { app.worktree(app.workbench.workspaceId)?.path }, prefix: "")
        if !openIn.items.isEmpty {
            file.add("Open Folder In", submenu: openIn)
        }
        menuBuilder.add(file, "-", "editor.reopenTab")
        let recent = NSMenu(title: "Recently Closed")
        recent.delegate = recentlyClosedMenu
        file.add("Recently Closed", submenu: recent)
        menuBuilder.add(
            file, "-", "editor.save", "editor.saveAll", "-", "editor.closeTab", "editor.closeOtherTabs",
            "editor.closeTabsToRight", "workspace.close")
        // What the rows' menus in the sidebar do, for what is in front: the chat, then its group, then its project.
        menuBuilder.add(
            file, "-", "agents.rename", "agents.markUnread", "agents.restart", "agents.fork", "agents.copyContext",
            "-", "workspace.renameGroup", "workspace.archiveGroup", "-", "workspace.renameProject",
            "workspace.removeProject")
    }

    /// Builds the Edit menu: undo, the clipboard, Find, and the editor's commands.
    private func editMenu(_ menuBuilder: MenuBuilder) {
        let edit = menuBuilder.sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Find, as in every Mac editor, has the panel, next / previous, and use selection.
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
            ("Find Next", "g", [.command], .next), ("Find Previous", "G", [.command, .shift], .previous),
            ("Use Selection for Find", "e", [.command], .setFindString)
        ] {
            let menuItem = find.addItem(
                withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mods
            menuItem.tag = Int(action.rawValue)
        }
        menuBuilder.add(find, "files.findInWorkspace", "files.findByName")
        menuBuilder.add(find, "files.search.matchCase", "files.search.wholeWord", "files.search.regex").forEach(
            menuBuilder.hide)   // only their keys, not more rows
        edit.add("Find", submenu: find)
        menuBuilder.add(
            edit, "editor.goToLine", "editor.nextProblem", "editor.previousProblem", "editor.showCompletions",
            "editor.showHover",
            "editor.jumpToDefinition", "editor.jumpToDefinitionBeside", "editor.findReferences", "editor.rename",
            "editor.quickFix",
            "editor.sendToAgent",
            "editor.copyReference", "editor.copyWebLink",
            "-", "editor.fold", "editor.unfold", "editor.foldAll", "editor.foldLevel2", "editor.foldLevel3",
            "editor.unfoldAll")
        let markdown = NSMenu(title: "Markdown")
        menuBuilder.add(
            markdown, "markdown.bold", "markdown.italic", "markdown.code", "markdown.link", "-", "markdown.bullets",
            "markdown.numbered",
            "markdown.tasks", "-", "markdown.cycleView")
        edit.add("Markdown", submenu: markdown)
    }

    /// Builds the Selection menu, with the code editor's commands as in VS Code. It comes after View, because a key
    /// goes to the first menu item that has it, whether that item is enabled or not. Outside the editor, ⌘D, ⌘[ and ⌘]
    /// are Split Right and the moves between panes (inside it, the editor takes them first, in EditorBox).
    private func selectionMenu(_ menuBuilder: MenuBuilder) {
        menuBuilder.add(
            menuBuilder.sub("Selection"), "editor.addNextOccurrence", "editor.selectAllOccurrences",
            "editor.expandSelection",
            "editor.shrinkSelection",
            "editor.cursorAbove", "editor.cursorBelow", "editor.cursorsAtLineEnds", "-", "editor.moveLinesUp",
            "editor.moveLinesDown",
            "editor.copyLinesUp", "editor.copyLinesDown", "editor.deleteLines", "-", "editor.toggleComment",
            "editor.indent", "editor.outdent")
    }

    /// Builds the View menu: the sidebar and inspector, panels, text size, panes and tabs.
    private func viewMenu(_ menuBuilder: MenuBuilder) {
        let app = self.app
        let view = menuBuilder.sub("View")
        menuBuilder.add(view, "workbench.toggleSidebar", "workbench.toggleInspector", "workbench.toggleFocusMode")
        // In the icon row's order, so the number is the icon's place in the row.
        for (i, p) in InspectorController.shown(app).prefix(9).enumerated() {
            let menuItem = view.add("  " + p.title, symbol: p.icon, key: "\(i + 1)") {
                app.extensions.run("workbench.showPanel", ["panel": .string(p.id), "keys": .bool(true)])
            }
            menuItem.keyEquivalentModifierMask = [.command, .option]
        }
        menuBuilder.placed.insert("workbench.showPanel")
        // The sidebar's blocks that can be hidden (Machines, Plan Limits), in the sidebar's order.
        let all = app.extensions.all.sidebarSections
        let blocks: [(String, Setting<Bool>)] = (all.filter { !$0.foot } + all.filter(\.foot)).compactMap {
            guard let title = $0.title, let shown = $0.shown else { return nil }
            return (title, shown)
        }
        if !blocks.isEmpty {
            view.addItem(.separator())
            view.addItem(.sectionHeader(title: "Sidebar Blocks"))
            for (title, shown) in blocks { view.addToggle(shown, app, title: title) }
        }
        menuBuilder.add(view, "-", "editor.toggleWordWrap", "-", "view.biggerText")
        // ⌘= enlarges the text too, as in Ghostty, VS Code and Safari (+ is the shifted =).
        menuBuilder.hide(view.add("Bigger Text", key: "=") { app.extensions.run("view.biggerText") })
        menuBuilder.add(
            view, "view.smallerText", "view.defaultTextSize", "-", "terminal.splitRight", "terminal.splitDown",
            "agents.sideBySide",
            "view.maximizePane", "view.equalizePanes")
        let panes = NSMenu(title: "Select Pane")
        menuBuilder.add(
            panes, "view.nextPane", "view.previousPane", "-", "view.paneLeft", "view.paneRight", "view.paneAbove",
            "view.paneBelow")
        view.add("Select Pane", submenu: panes)
        menuBuilder.add(view, "-", "editor.nextTab", "editor.previousTab")
        for n in 1...9 {
            menuBuilder.add(view, "editor.tab.\(n)").forEach {
                $0.isHidden = n > 3
                $0.allowsKeyEquivalentWhenHidden = true
            }
        }
        // ⌃Tab / ⌃⇧Tab open the workspace switcher (in the Window menu), and tabs keep ⇧⌘] / ⇧⌘[.
        menuBuilder.add(view, "-", "workbench.commandPalette", "files.quickOpen", "agents.history", "-")
        view.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        )
        .keyEquivalentModifierMask = [.command, .control]
    }

    /// Builds the Run menu: the project's commands (the built-in that runs them fills in the rest) and the editor's
    /// run, test and format.
    private func runMenu(_ menuBuilder: MenuBuilder) {
        let runs = menuBuilder.sub("Run")
        runs.delegate = app.extensions.all.runs?.menu   // the project's other commands go between the separators
        menuBuilder.add(
            runs, "scripts.run", "scripts.choose", "scripts.test", "scripts.stop", "scripts.openPage", "-", "-",
            "editor.runFile", "editor.testAtCursor", "editor.format", "-", "scripts.edit")
    }

    /// Builds the Window menu: workspaces, the agent needing you, and archived workspaces.
    private func windowMenu(_ menuBuilder: MenuBuilder) {
        let app = self.app
        let win = menuBuilder.sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        menuBuilder.add(win, "workbench.ownWindow", "workbench.saveTemplate")
        win.addItem(.separator())
        menuBuilder.add(
            win, "agents.nextNeedingYou", "agents.overview", "agents.usage", "workbench.scratch", "workspace.switch")
        let back = win.add(String(localized: "Previous Screen"), key: "\t") {
            app.extensions.run("workspace.switch", ["by": -1])
        }
        back.keyEquivalentModifierMask = [.control, .shift]
        menuBuilder.add(win, "workspace.next", "workspace.previous", "workspace.back", "workspace.forward")
        for n in 1...9 {
            menuBuilder.add(win, "workspace.select.\(n)").forEach {
                $0.isHidden = n > 1
                $0.allowsKeyEquivalentWhenHidden = true
            }
        }
        win.addItem(.separator())
        let archived = NSMenu(title: "Archived Groups")
        archived.delegate = archivedMenu
        win.add("Archived Groups", submenu: archived)
        win.addItem(.separator())
        win.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win
    }

    /// Builds the Help menu, where macOS puts its menu search.
    private func helpMenu(_ menuBuilder: MenuBuilder) {
        let help = menuBuilder.sub("Help")
        menuBuilder.add(help, "help.guide", "help.extensionGuide")
        NSApp.helpMenu = help
    }
}
