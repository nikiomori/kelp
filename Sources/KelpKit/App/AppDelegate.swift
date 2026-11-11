import Agents
import AppKit
import Core
import DesignKit
import EditorKit
import Sparkle
import WorkbenchKit

/// Runs the app with these built-in extensions (the app's target lists them: KelpKit names none). Never returns.
@MainActor
package func runApp(builtins: [Builtin]) -> Never {
    // Holding a key repeats it (j in vim, ← in an agent's prompt) instead of opening the accent picker, as in Terminal.
    UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    // Kelp has its own tabs: no "Show Tab Bar" / "Merge All Windows" from AppKit's window tabbing.
    NSWindow.allowsAutomaticWindowTabbing = false
    let delegate = AppDelegate(builtins: builtins)   // makes the app (`AppModel`) and hands it down
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app: made here, handed down to everything else.
    let app: AppModel
    init(builtins: [Builtin]) { app = AppModel(builtins: builtins) }
    private(set) var main: MainWindowController!
    private(set) lazy var notifier = Notifier(app: app)
    private lazy var dockIcon = DockIcon(app: app)
    /// Files and links opened while Kelp starts (nil once it has).
    private var pendingOpens: [URL]? = []
    /// Sparkle needs a feed URL in Info.plist: a bare binary and `make dev`'s Kelp Dev (whose plist drops it) skip it.
    lazy var updater: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: app.updates, userDriverDelegate: nil)
        app.updates.controller = controller   // Settings › General reads and sets its schedule
        return controller
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        let app = self.app
        NSApp.setActivationPolicy(.regular)
        Self.watchHangs()
        LatinShortcuts.install()
        app.extensions.reload()
        app.themes.follow()
        main = MainWindowController(app: app)
        main.showWindow(nil)
        app.noProject.registerHotKey()
        app.notifier = notifier
        notifier.start()
        dockIcon.start()
        for start in app.extensions.all.launched { start() }
        buildMenu()
        // Glances are timed only while some finished agent is still unread: no clock runs the rest of the time.
        track(owner: self) { [app] in
            app.sessions.contains { Self.readOnSight($0) }
        } changed: { [weak self] any in
            self?.timeGlances(any)
        }
        track(owner: self) { [app] in
            MenuSources(
                revision: app.extensions.revision, agents: app.availability.ids, keys: app.settings[SettingKeys.keys],
                update: app.updates.ready)
        } changed: { [weak self] _ in
            self?.buildMenu()
        }
        app.extensions.watch()
        Task {
            await app.daemon.connect()
            await app.noProject.ensure()   // connecting reloaded the extensions: settings (disabled ones) and what was allowed are known
            app.availability.refresh(force: true)
            #if DEBUG
                let pick = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_WORKTREE"].flatMap { name in
                    app.worktrees.first { $0.id == name || $0.branch == name || $0.note == name }
                }
            #else
                let pick: Worktree? = nil
            #endif
            let last = app.uiState["workbench.lastWorkspace"]?.string.flatMap { app.worktree($0) }
            // Next turn of the run loop: the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            // The first run's Welcome, not the No Project screen, when there's nothing to go back to.
            let first = app.worktrees.first { !$0.archived && !NoProject.holds(app.repo($0.repoId)) }
            if let workspace = pick ?? last ?? first { app.workbench.show(workspace: workspace.id) }
            await UnsavedBackups.reopen(app, in: app.workbench.editors)
            app.updates.sayInstalled()
            let early = pendingOpens ?? []
            pendingOpens = nil
            if !early.isEmpty { application(NSApp, open: early) }
        }
        NSApp.activate()
        // Snapshots and the input they drive (KELP_CLICK, KELP_TYPE…) are a debug build's: in a release, any program the
        // user runs could start the real app and have it click its own Trust button.
        #if DEBUG
            if let out = ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] { snapshotLater(out) }
        #endif
    }

    /// Agents installed while Kelp was in the background show up when it comes back.
    func applicationDidBecomeActive(_ n: Notification) {
        app.availability.refresh()
        notifier.checkAllowed()
    }
    /// Banners held while you typed go out once you're elsewhere.
    func applicationDidResignActive(_ n: Notification) { notifier.releaseHeld() }

    /// Unsaved files ask before quitting, like any Mac app: the question is a sheet, and the app quits once it's answered
    /// and any remote file's save came back (not if one failed).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let edited = app.workbench.editedFiles
        guard !edited.isEmpty, !unsavedAnswered else { return confirmQuit() }
        let system = Self.systemQuit
        var answered: Bool?
        Task {
            let answer = await runSheet(UnsavedChanges.alert(edited, quitting: true))
            let done = await UnsavedChanges.settle(edited, answer)
            answered = done ? await UnsavedChanges.written(edited) : false
            if answered == true, !system {
                unsavedAnswered = true
                NSApp.terminate(nil)
            }
        }
        // Logging out or shutting down: a cancel here cancels it, so the answer is waited for in place, events and
        // the main actor's tasks served meanwhile. Not `terminateLater`: until its reply AppKit runs a modal mode in
        // which the main actor's tasks don't run, so the question could never be asked.
        guard system else { return .terminateCancel }   // ⌘Q: asked in a sheet, then quit again
        while answered == nil {
            if let event = NSApp.nextEvent(matching: .any, until: .now + 0.1, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return answered == true ? .terminateNow : .terminateCancel
    }
    /// The quit macOS asks for when the user logs out, restarts or shuts down (its Apple event says why); a ⌘Q or a
    /// script's quit gives no reason.
    private static var systemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
    /// The quit question was answered (saved, or Don't Save): the next terminate goes through.
    private var unsavedAnswered = false

    /// Settings › General › Ask before quitting: ⌘Q and closing the window ask in a sheet. A relaunch, an update, a
    /// logout and an answered unsaved-files question are a choice already, so they don't.
    private func confirmQuit() -> NSApplication.TerminateReply {
        guard app.settings[SettingKeys.confirmQuit], !Self.quitChosen, !unsavedAnswered, !Self.systemQuit else {
            return .terminateNow
        }
        guard !askingToQuit else { return .terminateCancel }   // a second ⌘Q while the sheet is up
        askingToQuit = true
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Are you sure you want to quit Kelp?")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            let quit = await runSheet(alert) == .alertFirstButtonReturn
            askingToQuit = false
            if alert.suppressionButton?.state == .on { app.settings.set(SettingKeys.confirmQuit, false) }
            guard quit else { return }
            Self.quitChosen = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }
    private var askingToQuit = false
    /// Set by quits the user chose some other way (Relaunch, Install Update): they don't ask again.
    static var quitChosen = false

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // the daemon keeps sessions alive
    /// A new copy, then this one quits: the daemon and everything running in it carry on under the new window.
    static func relaunch() {
        let fresh = NSWorkspace.OpenConfiguration()
        fresh.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: fresh) { _, error in
            Task { @MainActor in
                if let error {
                    Banner.show(
                        String(localized: "Couldn't relaunch Kelp: \(error.localizedDescription)"), style: .error)
                } else {
                    quitChosen = true
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        main?.leaveFocusMode()
        app.workbench.layouts.save()   // a tab moved in the last half second
        app.flush()
    }

    /// Folders dropped on the Dock icon or opened with `open -a Kelp <path>` become projects; files open as tabs.
    /// What opens Kelp waits for the projects and the last workspace to be on screen.
    func application(_ sender: NSApplication, open urls: [URL]) {
        if pendingOpens != nil {
            pendingOpens? += urls
            return
        }
        for u in urls where u.scheme == "kelp" { KelpLinks(app).handle(u) }
        app.workbench.open(files: urls.filter(\.isFileURL))
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockIcon.menu() }

    /// Finished agents read at a glance (`Glances`): timed only while one is unread, so no clock runs the rest of the time.
    private var glances = Glances()
    private var glanceClock: Timer?
    private static func readOnSight(_ s: Session) -> Bool {
        s.unread && (s.status == .done || (s.status == .exited && !s.endedWithError))
    }
    private func timeGlances(_ on: Bool) {
        glanceClock?.invalidate()
        glanceClock = nil
        glances = Glances()
        guard on else { return }
        // Main run loop: AppKit runs the timer on the main thread.
        glanceClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackGlances() }
        }
    }
    private func trackGlances() {
        let window = main?.window, editor = app.workbench.editor
        // And someone is there: a front window in an empty room reads nothing (`Presence`).
        let front =
            NSApp.isActive && window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
            && editor != nil
            && Presence.here()
        let app = app
        let mark = glances.tick(
            front: front, shown: editor?.attendedSessions ?? [],
            readable: { app.session($0).map(Self.readOnSight) ?? false },
            unread: { app.session($0)?.unread == true }, now: Date())
        for sid in mark {
            Task { [weak self] in if await self?.app.call(SessionMarkRead(id: sid)) == nil { self?.glances.failed(sid) }
            }   // try again later
        }
    }

    // MARK: menu
    /// A menu item (the menu bar's or the sidebar's Add Project menu) runs the command its identifier names.
    @objc func runCommand(_ sender: Any?) {
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        app.extensions.command(id)?.run([:])
    }

    private(set) lazy var archivedMenu = ArchivedMenu(app: app)
    private(set) lazy var recentlyClosedMenu = RecentlyClosedMenu(app: app)

    /// The command's menu item: its identifier is the command id (Settings › Keyboard, `validateMenuItem`).
    func item(_ c: CommandSpec) -> NSMenuItem {
        let menuItem = NSMenuItem(title: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.identifier = NSUserInterfaceItemIdentifier(c.id)
        if let spec = c.key.flatMap(KeySpec.init) {
            menuItem.keyEquivalent = spec.key
            menuItem.keyEquivalentModifierMask = spec.mods.flags
        }
        return menuItem
    }
}

/// What the menu bar is built from: it's built again when any of it changes.
private struct MenuSources: Equatable {
    let revision: Int, agents: Set<String>, keys: JSONValue?, update: Updates.Ready?
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does; Focus Mode is ticked while it's on; Stop needs something running;
    /// the file commands need a file.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "workbench.toggleSidebar":
            item.title = main.sidebarShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case "workbench.toggleInspector":
            item.title = main.inspectorShown ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case "workbench.toggleFocusMode": item.state = main.inFocusMode ? .on : .off
        case "power.keepAwake": item.state = app.settings[SettingKeys.keepAwake] == "always" ? .on : .off
        // Off elsewhere, so a terminal still gets ⌥Z.
        case "editor.toggleWordWrap":
            item.state =
                app.settings[SettingKeys.wordWrap, language: CodeEditor.focused?.languageId] ? .on : .off
            return app.workbench.editor?.focusedContent?.fileURL != nil
        case "editor.reopenTab": return app.workbench.nextClosedTab != nil   // off elsewhere, so a terminal still gets the key
        // Off elsewhere, so a terminal still gets their keys.
        case "editor.runFile", "editor.testAtCursor", "editor.format":
            return app.workbench.editor?.focusedContent?.fileURL != nil
        case "editor.findReferences", "editor.rename", "editor.quickFix",
            "editor.nextProblem", "editor.previousProblem", "editor.showCompletions", "editor.showHover",
            "editor.expandSelection", "editor.shrinkSelection",
            "editor.cursorAbove", "editor.cursorBelow", "editor.cursorsAtLineEnds",
            "editor.addNextOccurrence", "editor.selectAllOccurrences", "editor.moveLinesUp", "editor.moveLinesDown",
            "editor.copyLinesUp", "editor.copyLinesDown", "editor.deleteLines", "editor.toggleComment", "editor.indent",
            "editor.outdent",
            "editor.fold", "editor.unfold", "editor.unfoldAll", "editor.foldAll", "editor.foldLevel2",
            "editor.foldLevel3":
            return CodeEditor.focused != nil
        // Off elsewhere: ⌘K still clears a terminal.
        case "markdown.bold", "markdown.italic", "markdown.code", "markdown.link", "markdown.bullets",
            "markdown.numbered", "markdown.tasks":
            return CodeEditor.focused?.isMarkdown == true
        // A command that says when it can run (Run › Stop: something runs).
        default:
            if let enabled = item.identifier.flatMap({ app.extensions.command($0.rawValue) })?.enabled {
                return enabled()
            }
        }
        return true
    }
}

/// Window › Archived Workspaces. The list is read from the daemon whenever the workspaces change, so the menu fills at once.
@MainActor
final class ArchivedMenu: NSObject, NSMenuDelegate {
    private let app: AppModel
    private var archived: [Worktree] = []
    private var failed: String?   // why the list couldn't be read: the menu says so instead of "None"
    init(app: AppModel) {
        self.app = app
        super.init()
        track(owner: self) { [app] in
            app.worktrees
        } changed: { [weak self] _ in
            Task { await self?.reload() }
        }
    }
    private func reload() async {
        let result = await app.tryCall(WorktreeList(archived: true))
        archived = (result.value ?? []).filter(\.archived)
        failed = result.error
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let failed {
            menu.addItem(withTitle: failed, action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        guard !archived.isEmpty else {
            menu.addItem(withTitle: String(localized: "None"), action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for w in archived.sorted(by: { $0.createdAt > $1.createdAt }) {
            menu.add("\(w.displayName) — \(app.projectName(w.repoId) ?? "")") { [app] in
                WorkspaceActions(app).unarchive(w.id)
            }
        }
    }
}
