import AppKit
import Core
import DesignKit
import WorkbenchKit

extension Builtins {
    /// The shell's own actions (sidebar and inspector, panes, tabs, workspaces, text size, the Run menu, help) as commands,
    /// so the menu bar, Settings › Keyboard, the palette and agents (`kelp run <id>`) reach them the same way.
    package static let workbench = Builtin("kelp.workbench", "Window & Workbench",
                                   "Panes, tabs, workspaces, the sidebar and inspector: the commands of the window.",
                                   icon: "macwindow", essential: true) { app in
        var c = Contributions()
        c.commands = [
            CommandSpec(id: "workbench.openSettings", title: "Settings…", key: "cmd+,") { a in SettingsWindow.show(app, section: a["section"]?.string) },
            cmd("workbench.openExtensions", "Extensions…") { SettingsWindow.show(app, section: "extensions") },
            cmd("workbench.restartService", "Restart Background Service…") { restartService(app) },
            cmd("workbench.toggleSidebar", "Show Sidebar", "cmd+0") { app.workbench.window?.toggleSidebarPanel() },
            cmd("workbench.toggleInspector", "Show Inspector", "opt+cmd+0") { app.workbench.window?.toggleInspectorPanel() },
            cmd("workbench.toggleFocusMode", "Focus Mode", "ctrl+cmd+z") { app.workbench.window?.toggleFocusMode() },
            CommandSpec(id: "workbench.showPanel", title: "Show Panel") { a in
                if let p = a["panel"]?.string { app.workbench.window?.showInspector(panel: p) }
            },
            cmd("workbench.commandPalette", "Command Palette…", "shift+cmd+p") { app.quickOpen.show(commandsOnly: true) },
            cmd("workbench.scratch", "Scratch", "ctrl+opt+cmd+k") { app.scratch.toggle() },
            cmd("view.biggerText", "Bigger Text", "cmd+plus") { zoomText(app, 1) },
            cmd("view.smallerText", "Smaller Text", "cmd+-") { zoomText(app, -1) },
            cmd("view.defaultTextSize", "Default Text Size") { zoomText(app, nil) },
            cmd("view.maximizePane", "Maximize Pane", "shift+cmd+return") { editor(app)?.toggleZoom() },
            cmd("view.equalizePanes", "Equalize Panes") { editor(app)?.equalizePanes() },
            cmd("view.nextPane", "Next Pane", "cmd+]") { editor(app)?.focusGroup(1) },
            cmd("view.previousPane", "Previous Pane", "cmd+[") { editor(app)?.focusGroup(-1) },
            // ⌥⌘ arrows, as Ghostty moves between splits
            cmd("view.paneLeft", "Pane on the Left", "opt+cmd+left") { editor(app)?.focusGroup(toward: .minX) },
            cmd("view.paneRight", "Pane on the Right", "opt+cmd+right") { editor(app)?.focusGroup(toward: .maxX) },
            cmd("view.paneAbove", "Pane Above", "opt+cmd+up") { editor(app)?.focusGroup(toward: .maxY) },
            cmd("view.paneBelow", "Pane Below", "opt+cmd+down") { editor(app)?.focusGroup(toward: .minY) },
            cmd("editor.nextTab", "Next Tab", "shift+cmd+]") { editor(app)?.cycleTab(1) },
            cmd("editor.previousTab", "Previous Tab", "shift+cmd+[") { editor(app)?.cycleTab(-1) },
            // ⌘W: the focused tab; in a workspace with nothing open, the workspace itself.
            cmd("editor.closeTab", "Close Tab", "cmd+w") {
                guard let e = editor(app) else { return }
                if e.focusedContent == nil, let w = e.worktree { WorkspaceActions(app).close(w) } else { e.closeFocusedTab() }
            },
            cmd("workspace.new", "New Workspace", "cmd+n") { app.workbench.newWorkspace() },
            cmd("workspace.addProject", "Add Project…", "cmd+o") { app.workbench.addProject() },
            cmd("workspace.cloneRepository", "Clone Repository…") { CloneSheet.show(app) },
            cmd("workspace.addRemote", "Open over SSH…") { RemoteSheet.show(app) },
            cmd("workspace.revealInFinder", "Reveal in Finder", "opt+cmd+r") { WorkspaceActions(app).revealCurrent() },
            cmd("workspace.close", "Close Workspace", "shift+cmd+w") { if let w = editor(app)?.worktree { WorkspaceActions(app).close(w) } },
            // ⌃Tab walks the workspaces used last (⌃⇧Tab: `{"by": -1}`).
            CommandSpec(id: "workspace.switch", title: "Switch Workspace", key: "ctrl+tab") { a in app.switcher.step(a["by"]?.int ?? 1) },
            cmd("workspace.next", "Next Workspace", "ctrl+cmd+down") { app.workbench.showWorkspace(offset: 1) },
            cmd("workspace.previous", "Previous Workspace", "ctrl+cmd+up") { app.workbench.showWorkspace(offset: -1) },
            // Back and forward through the workspaces you visited.
            cmd("workspace.back", "Back", "ctrl+cmd+left") { app.workbench.goBack(-1) },
            cmd("workspace.forward", "Forward", "ctrl+cmd+right") { app.workbench.goBack(1) },
            // The Run menu: the project's commands from .kelp.yaml (`{"name": "lint"}` runs another one).
            CommandSpec(id: "scripts.run", title: "Run", key: "cmd+r") { a in app.scripts.run(a["name"]?.string ?? "run") },
            cmd("scripts.test", "Test", "cmd+u") { app.scripts.run("test") },
            cmd("scripts.stop", "Stop", "cmd+.") { app.scripts.stop() },
            cmd("scripts.edit", "Edit Commands…") { app.scripts.edit() },
            cmd("help.guide", "How Kelp Works", "cmd+?") { app.workbench.open(TabURI.file(Help.file.path)) },
            cmd("help.extensionGuide", "Writing Extensions") {
                app.workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path))
            }
        ]
        // Like VS Code's openEditorAtIndex1…9: one id per number, so each can be rebound.
        c.commands += (1...9).map { n in cmd("editor.tab.\(n)", "Tab \(n)", "cmd+\(n)") { editor(app)?.selectTab(index: n - 1) } }
        c.commands += (1...9).map { n in cmd("workspace.select.\(n)", "Workspace \(n)", "ctrl+\(n)") { app.workbench.showWorkspace(number: n) } }
        return c
    }

    /// Terminal and editor text zoom together, like a browser; the settings stay the one source.
    private static func zoomText(_ app: AppModel, _ step: Double?) {
        let s = app.settings
        for key in ["terminal.fontSize", "editor.fontSize"] {
            s.set(key, .double(step.map { min(40, max(8, (s.number(key) ?? 13) + $0)) } ?? 13))
        }
    }

    /// A kelpd that runs itself again in place keeps every agent running, so nothing is asked; an older one ends them.
    private static func restartService(_ app: AppModel) {
        Task {
            if await app.restartDaemon(keepingSessions: true) { return }
            let a = NSAlert(); a.messageText = String(localized: "Restart the background service?")
            a.informativeText = String(localized: "Running agent sessions end. Workspaces, history and settings are kept.")
            a.addButton(withTitle: String(localized: "Restart")); a.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(a) == .alertFirstButtonReturn { await app.restartDaemon() }
        }
    }
}
