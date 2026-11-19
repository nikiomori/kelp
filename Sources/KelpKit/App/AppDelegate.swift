import Agents
import AppKit
import Core
import DesignKit
import EditorKit
import Sparkle
import WorkbenchKit

/// Runs the app with these built-in extensions. The app's target lists them, so KelpKit names none. Never returns.
@MainActor
package func runApp(builtins: [Builtin]) -> Never {
    // Holding a key repeats it (j in vim, ← in an agent's prompt) instead of opening the accent picker, as in Terminal.
    UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    // Kelp has its own tabs, so AppKit's window tabbing ("Show Tab Bar", "Merge All Windows") is turned off.
    NSWindow.allowsAutomaticWindowTabbing = false
    let delegate = AppDelegate(builtins: builtins)   // makes the app (`AppModel`) and hands it down
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app model, made here and handed down to everything else.
    let app: AppModel
    init(builtins: [Builtin]) { app = AppModel(builtins: builtins) }
    private(set) var main: MainWindowController!
    private(set) lazy var notifier = Notifier(app: app)
    private lazy var dockIcon = DockIcon(app: app)
    /// Files and links opened while Kelp starts, or nil once it has started.
    private var pendingOpens: [URL]? = []
    /// Sparkle's updater. Sparkle needs a feed URL in Info.plist, so a bare binary and `make dev`'s Kelp Dev (whose
    /// plist drops it) have none. It starts after the window's first frame (`showWhenSettingsArrive`), not before.
    lazy var updater: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: app.updates, userDriverDelegate: nil)
        app.updates.controller = controller   // Settings › General reads and sets the updater's schedule
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = self.app
        NSApp.setActivationPolicy(.regular)
        Self.watchHangs()
        LatinShortcuts.install()
        app.extensions.reload()
        app.themes.follow()
        main = MainWindowController(app: app)
        showWhenSettingsArrive()
        app.noProject.registerHotKey()
        app.notifier = notifier
        notifier.start()
        dockIcon.start()
        for start in app.extensions.all.launched { start() }
        buildMenu()
        // Glances are timed only while some finished agent is still unread, so no clock runs the rest of the time.
        track(owner: self) { [app] in
            app.sessions.contains { Self.readOnSight($0) }
        } changed: { [weak self] any in
            self?.unreadToGlance = any
            self?.timeGlances()
        }
        followSight()
        track(owner: self) { [app] in
            MenuSources(
                revision: app.extensions.revision, agents: app.availability.ids, keys: app.settings[SettingKeys.keys],
                update: app.updates.ready, panels: InspectorController.shown(app).map(\.id))
        } changed: { [weak self] _ in
            self?.buildMenu()
        }
        app.extensions.watch()
        Task {
            await app.daemon.connect()
            await app.noProject.ensure()   // connecting reloaded extensions, so disabled and allowed ones are known
            app.availability.refresh(force: true)
            #if DEBUG
                let pick = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_WORKTREE"].flatMap { name in
                    app.worktrees.first { $0.id == name || $0.branch == name || $0.note == name }
                }
            #else
                let pick: Worktree? = nil
            #endif
            let last = app.uiState["workbench.lastWorkspace"]?.string.flatMap { app.worktree($0) }
            // Wait for the next turn of the run loop, so the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            // With nothing to go back to, the first run shows Welcome, not the No Project screen.
            let first = app.worktrees.first { !$0.archived && !NoProject.holds(app.repo($0.repoId)) }
            if let workspace = pick ?? last ?? first { app.workbench.show(workspace: workspace.id) }
            app.workbench.reopenOwnWindows()
            await UnsavedBackups.reopen(app, in: app.workbench.editors)
            app.updates.sayInstalled()
            let early = pendingOpens ?? []
            pendingOpens = nil
            if !early.isEmpty { application(NSApp, open: early) }
        }
        NSApp.activate()
        // Snapshots and the input they drive (KELP_CLICK, KELP_TYPE…) exist only in a debug build. In a release, any
        // program the user runs could start the real app and have it click its own Trust button.
        #if DEBUG
            if let out = ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] { snapshotLater(out) }
        #endif
    }

    /// Looks for agents again when Kelp comes to the front, so agents installed meanwhile show up.
    func applicationDidBecomeActive(_ notification: Notification) {
        app.availability.refresh()
        notifier.checkAllowed()
    }
    /// Sends the banners held while you typed, once you're in another app.
    func applicationDidResignActive(_ notification: Notification) { notifier.releaseHeld() }

    /// Asks about unsaved files before quitting, like any Mac app. The question is a sheet, and the app quits once it's
    /// answered and every remote file's save has come back (but not if one failed).
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
        // When logging out or shutting down, a cancel here cancels the logout, so the answer is waited for in place,
        // serving events and the main actor's tasks meanwhile. `terminateLater` won't do, because until its reply
        // AppKit runs a modal mode in which the main actor's tasks don't run, so the question could never be asked.
        guard system else { return .terminateCancel }   // ⌘Q asks in a sheet, then quits again
        while answered == nil {
            if let event = NSApp.nextEvent(matching: .any, until: .now + 0.1, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return answered == true ? .terminateNow : .terminateCancel
    }
    /// Whether macOS asked to quit because the user logs out, restarts or shuts down (the quit's Apple event says
    /// why). A ⌘Q or a script's quit gives no reason.
    private static var systemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
    /// Whether the unsaved-files question was answered (saved, or Don't Save), so the next terminate goes through.
    private var unsavedAnswered = false

    /// Asks before quitting when Settings › General › Ask before quitting is on, so ⌘Q and closing the window ask in a
    /// sheet. A relaunch, an update, a logout and an answered unsaved-files question are already a choice, so they
    /// don't ask.
    private func confirmQuit() -> NSApplication.TerminateReply {
        guard app.settings[SettingKeys.confirmQuit], !Self.quitChosen, !unsavedAnswered, !Self.systemQuit else {
            return .terminateNow
        }
        guard !askingToQuit else { return .terminateCancel }   // ignores a second ⌘Q while the sheet is up
        askingToQuit = true
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit Kelp?")   // as the setting that turns this off promises it
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
    /// Set by quits the user chose some other way (Relaunch, Install Update), so those don't ask again.
    static var quitChosen = false

    /// Quits with the last window, because the daemon keeps the sessions alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool { true }
    /// Opens a new copy of Kelp, then quits this one. The daemon and everything running in it carry on under the new
    /// window.
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

    func applicationWillTerminate(_ notification: Notification) {
        main?.leaveFocusMode()
        app.workbench.layouts.save()   // saves a tab moved in the last half second
        app.flush()
    }

    /// Folders dropped on the Dock icon or opened with `open -a Kelp <path>` become projects, and files open as tabs.
    /// Whatever opens Kelp this way waits until the projects and the last workspace are on screen.
    func application(_ sender: NSApplication, open urls: [URL]) {
        if pendingOpens != nil {
            pendingOpens? += urls
            return
        }
        for u in urls where u.scheme == "kelp" { KelpLinks(app).handle(u) }
        app.workbench.open(files: urls.filter(\.isFileURL))
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockIcon.menu() }

    /// Follows Kelp going behind or coming forward (for the glance clock), and its windows being seen or not
    /// (`AppModel.setAway`). While they're all hidden, minimized or covered, what only they show isn't read.
    private func followSight() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            sight.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.timeGlances() }   // queue: .main
                })
        }
        // Watch every window, because a group's own window or a page's window keeps Kelp in sight while the main
        // window is covered.
        let seen = NSWindow.didChangeOcclusionStateNotification
        sight.append(
            center.addObserver(forName: seen, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.app.workbench.sightChanged() }   // queue: .main
            })
    }
    /// The observers above, held for as long as the delegate lives (the app's whole run).
    private var sight: [NSObjectProtocol] = []

    /// Tracks finished agents read at a glance (`Glances`). It is timed only while one is unread, so no clock runs the
    /// rest of the time.
    private var glances = Glances()
    private var glanceClock: Timer?
    private static func readOnSight(_ session: Session) -> Bool {
        session.unread && (session.status == .done || (session.status == .exited && !session.endedWithError))
    }
    /// Whether some finished agent is unread. Glances are timed only while Kelp is the app in front, because none can
    /// happen while it is behind.
    private var unreadToGlance = false
    private func timeGlances() {
        glanceClock?.invalidate()
        glanceClock = nil
        glances = Glances()
        guard unreadToGlance, NSApp.isActive else { return }
        // The timer is on the main run loop, so AppKit runs it on the main thread.
        glanceClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackGlances() }
        }
    }
    private func trackGlances() {
        // Use the editor area of the window in front (the main one or a group's own), and only while someone is at the
        // Mac, because a front window in an empty room reads nothing (`Presence`).
        let editor = NSApp.isActive && Presence.here() ? app.workbench.editorInFront() : nil
        let app = app
        let mark = glances.tick(
            front: editor != nil, shown: editor?.attendedSessions ?? [],
            readable: { app.session($0).map(Self.readOnSight) ?? false },
            unread: { app.session($0)?.unread == true }, now: Date())
        for sid in mark {
            Task { [weak self] in if await self?.app.call(SessionMarkRead(id: sid)) == nil { self?.glances.failed(sid) }
            }   // try again later
        }
    }

    // MARK: menu
    /// Runs the command that a menu item's identifier names (for the menu bar and the sidebar's Add Project menu).
    @objc func runCommand(_ sender: Any?) {
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        app.extensions.command(id)?.run([:])
    }

    private(set) lazy var archivedMenu = ArchivedMenu(app: app)
    private(set) lazy var recentlyClosedMenu = RecentlyClosedMenu(app: app)

    /// Makes the command's menu item. Its identifier is the command id (for Settings › Keyboard and
    /// `validateMenuItem`).
    func item(_ commandSpec: CommandSpec) -> NSMenuItem {
        let menuItem = NSMenuItem(title: commandSpec.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.identifier = NSUserInterfaceItemIdentifier(commandSpec.id)
        if let spec = commandSpec.key.flatMap(KeySpec.init) {
            menuItem.keyEquivalent = spec.key
            menuItem.keyEquivalentModifierMask = spec.mods.flags
        }
        return menuItem
    }
}

/// What the menu bar is built from. The menu bar is built again when any of this changes.
private struct MenuSources: Equatable {
    let revision: Int, agents: Set<String>, keys: JSONValue?, update: Updates.Ready?
    /// The inspector's icons in their order: View numbers the panels by it.
    let panels: [String]
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does, Focus Mode is ticked while it is on, Stop needs something running,
    /// and the file commands need a file. The window is asked as `main?`, because there is none until launch and a
    /// test checks the menu bar without one.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "workbench.toggleSidebar":
            item.title =
                main?.sidebarShown == true ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case "workbench.toggleInspector":
            item.title =
                main?.inspectorShown == true
                ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case "workbench.toggleFocusMode": item.state = main?.inFocusMode == true ? .on : .off
        case "power.keepAwake": item.state = app.settings[SettingKeys.keepAwake] == "always" ? .on : .off
        // Disabled outside a file, so a terminal still gets ⌥Z.
        case "editor.toggleWordWrap":
            item.state =
                app.settings[SettingKeys.wordWrap, language: CodeEditor.focused?.languageId] ? .on : .off
            return app.workbench.editor?.focusedContent?.fileURL != nil
        case "editor.reopenTab": return app.workbench.nextClosedTab != nil   // off elsewhere, so a terminal still gets the key
        // Disabled outside a file, so a terminal still gets their keys.
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
        // Disabled outside Markdown, so ⌘K still clears a terminal.
        case "markdown.bold", "markdown.italic", "markdown.code", "markdown.link", "markdown.bullets",
            "markdown.numbered", "markdown.tasks":
            return CodeEditor.focused?.isMarkdown == true
        // A command that says when it can run (Run › Stop can run while something runs).
        default:
            if let enabled = item.identifier.flatMap({ app.extensions.command($0.rawValue) })?.enabled {
                return enabled()
            }
        }
        return true
    }
}

/// The Window › Archived Workspaces menu. The list is read from the daemon whenever the workspaces change, so the menu
/// fills at once.
@MainActor
final class ArchivedMenu: NSObject, NSMenuDelegate {
    private let app: AppModel
    private var archived: [Worktree] = []
    private var failed: String?   // why the list couldn't be read, which the menu shows instead of "None"
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
