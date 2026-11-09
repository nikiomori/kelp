import AppKit
import Core
import DesignKit
import WorkbenchKit

extension Builtins {
    /// The shell's own actions (sidebar and inspector, panes, tabs, workspaces, text size, the Run menu, help) as commands,
    /// so the menu bar, Settings › Keyboard, the palette and agents (`kelp run <id>`) reach them the same way.
    package static let workbench = Builtin(
        "kelp.workbench", "Window & Workbench",
        "Panes, tabs, groups, the sidebar and inspector: the commands of the window.",
        icon: "macwindow", essential: true
    ) { app in
        var contributions = Contributions()
        contributions.commands = [
            CommandSpec(id: "workbench.openSettings", title: "Settings…", key: "cmd+,") { args in
                SettingsWindow.show(app, section: args["section"]?.string, group: args["group"]?.string)
            },
            cmd("workbench.openExtensions", "Extensions…") { SettingsWindow.show(app, section: "extensions") },
            cmd("workbench.restartService", "Restart Background Service…") { restartService(app) },
            cmd("workbench.toggleSidebar", "Show Sidebar", "cmd+0") { app.workbench.window?.toggleSidebarPanel() },
            cmd("workbench.toggleInspector", "Show Inspector", "opt+cmd+0") {
                app.workbench.window?.toggleInspectorPanel()
            },
            cmd("workbench.toggleFocusMode", "Focus Mode", "ctrl+cmd+z") { app.workbench.window?.toggleFocusMode() },
            CommandSpec(id: "workbench.showPanel", title: "Show Panel") { args in
                if let panel = args["panel"]?.string { app.workbench.window?.showInspector(panel: panel) }
            },
            cmd("workbench.commandPalette", "Command Palette…", "shift+cmd+p") {
                app.quickOpen.show(commandsOnly: true)
            },
            cmd("workbench.scratch", "New Chat Without Project", "ctrl+opt+cmd+k") { app.noProject.newChat() },
            // Settings › Notifications' button: macOS shows the banner, or Kelp says where they're turned off.
            cmd("notifications.test", "Send Test Notification") {
                app.notifier?.sendTest { ok in
                    if !ok {
                        Banner.show(
                            String(localized: "Turned off for Kelp in System Settings › Notifications."), style: .error)
                    }
                }
            },
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
                guard let area = editor(app) else { return }
                if area.focusedContent == nil, let worktree = area.worktree {
                    WorkspaceActions(app).close(worktree)
                } else {
                    area.closeFocusedTab()
                }
            },
            cmd("editor.reopenTab", "Reopen Closed Tab", "shift+cmd+t") { app.workbench.reopenClosedTab() },
            cmd("workspace.new", "New Chat", "cmd+n") { app.workbench.newChat() },
            cmd("workspace.newGroup", "New Group", "shift+cmd+n") { app.workbench.newGroup() },
            cmd("workspace.newBranch", "New Chat on Branch", "ctrl+cmd+n") { app.workbench.newBranch() },
            cmd("workspace.newBranchAsking", "New Chat on Branch…", "opt+ctrl+cmd+n") {
                app.workbench.newBranchAsking()
            },
            cmd("workspace.addProject", "Add Project…", "cmd+o") { app.workbench.addProject() },
            cmd("workspace.cloneRepository", "Clone Repository…") { CloneSheet.show(app) },
            cmd("workspace.addRemote", "Open over SSH…") { RemoteSheet.show(app) },
            cmd("workspace.revealInFinder", "Reveal in Finder", "opt+cmd+r") { WorkspaceActions(app).revealCurrent() },
            cmd("workspace.close", "Close Group", "shift+cmd+w") {
                if let worktree = editor(app)?.worktree { WorkspaceActions(app).close(worktree) }
            },
            // ⌃Tab walks the workspaces used last (⌃⇧Tab: `{"by": -1}`).
            CommandSpec(id: "workspace.switch", title: "Recent Screens", key: "ctrl+tab") { args in
                app.switcher.step(args["by"]?.int ?? 1)
            },
            cmd("workspace.next", "Next Group", "ctrl+cmd+down") { app.workbench.showWorkspace(offset: 1) },
            cmd("workspace.previous", "Previous Group", "ctrl+cmd+up") { app.workbench.showWorkspace(offset: -1) },
            // Back and forward through the workspaces you visited.
            cmd("workspace.back", "Back", "ctrl+cmd+left") { app.workbench.goBack(-1) },
            cmd("workspace.forward", "Forward", "ctrl+cmd+right") { app.workbench.goBack(1) },
            cmd("help.guide", "How Kelp Works", "cmd+?") { app.workbench.open(TabURI.file(Help.file.path)) },
            cmd("help.extensionGuide", "Writing Extensions") {
                app.workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path))
            }
        ]
        // Like VS Code's openEditorAtIndex1…9: one id per number, so each can be rebound.
        contributions.commands += (1...9).map { number in
            cmd("editor.tab.\(number)", "Tab \(number)", "cmd+\(number)") { editor(app)?.selectTab(index: number - 1) }
        }
        contributions.commands += (1...9).map { number in
            cmd("workspace.select.\(number)", "Group \(number)", "ctrl+\(number)") {
                // With ⌃Tab's list open, its rows' numbers: the menu may get ⌃1–9 before the list's own keys do.
                if app.switcher.isOpen {
                    app.switcher.pick(number)
                } else {
                    app.workbench.showWorkspace(number: number)
                }
            }
        }
        return contributions
    }

    /// Terminal and editor text zoom together, like a browser; the settings stay the one source.
    private static func zoomText(_ app: AppModel, _ step: Double?) {
        let settings = app.settings
        for setting in [SettingKeys.terminalFontSize, SettingKeys.editorFontSize] {
            settings.set(setting.key, .double(step.map { min(40, max(8, settings[setting] + $0)) } ?? setting.fallback))
        }
    }

    /// A kelpd that runs itself again in place keeps every agent running, so nothing is asked; an older one ends them.
    private static func restartService(_ app: AppModel) {
        Task {
            if await app.restartDaemon(keepingSessions: true) { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Restart the background service?")
            alert.informativeText = String(
                localized: "Running agent sessions end. Projects, history and settings are kept.")
            alert.addButton(withTitle: String(localized: "Restart"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(alert) == .alertFirstButtonReturn { await app.restartDaemon() }
        }
    }
}
