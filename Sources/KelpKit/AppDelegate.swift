import AppKit
import Core
import Agents
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
    /// Files and links opened while Kelp starts (nil once it has).
    private var pendingOpens: [URL]? = []
    /// Sparkle needs a real app bundle (feed URL and keys live in Info.plist); dev runs skip it.
    lazy var updater: SPUStandardUpdaterController? = Bundle.main.bundleIdentifier == nil ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ n: Notification) {
        let app = self.app
        NSApp.setActivationPolicy(.regular)
        Self.watchHangs()
        LatinShortcuts.install()
        app.extensions.reload()
        main = MainWindowController(app: app)
        main.showWindow(nil)
        app.scratch.registerHotKey()
        app.notifier = notifier; notifier.start()
        buildMenu()
        // Glances are timed only while some finished agent is still unread: no clock runs the rest of the time.
        track(owner: self) { [app] in app.sessions.contains { Self.readOnSight($0) } } changed: { [weak self] any in self?.timeGlances(any) }
        track(owner: self) { [app] in app.extensions.revision } changed: { [weak self] _ in self?.buildMenu() }
        track(owner: self) { app.availability.ids } changed: { [weak self] _ in self?.buildMenu() }
        track(owner: self) { [app] in app.settings.value("keys") } changed: { [weak self] _ in self?.buildMenu() }
        app.extensions.watch()
        Task {
            await app.connect()
            app.extensions.reload()   // settings (disabled extensions) are known now
            app.availability.refresh(force: true)
            #if DEBUG
            let pick = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_WORKTREE"].flatMap { b in
                app.worktrees.first { $0.id == b || $0.branch == b || $0.note == b }
            }
            #else
            let pick: Worktree? = nil
            #endif
            let last = app.uiState["workbench.lastWorkspace"]?.string.flatMap { app.worktree($0) }
            // Next turn of the run loop: the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            if let w = pick ?? last ?? app.worktrees.first(where: { !$0.archived }) { app.workbench.show(workspace: w.id) }
            let early = pendingOpens ?? []; pendingOpens = nil
            if !early.isEmpty { application(NSApp, open: early) }
            if ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] == nil { OnboardingSheet.showIfFirstLaunch(app) }
        }
        NSApp.activate()
        // Snapshots and the input they drive (KELP_CLICK, KELP_TYPE…) are a debug build's: in a release, any program the
        // user runs could start the real app and have it click its own Trust button.
        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] { snapshotLater(out) }
        #endif
    }

    /// Agents installed while Kelp was in the background show up when it comes back.
    func applicationDidBecomeActive(_ n: Notification) { app.availability.refresh(); notifier.checkAllowed() }

    /// Unsaved files ask before quitting, like any Mac app: the question is a sheet, and the app quits once it's answered
    /// and any remote file's save came back (not if one failed).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let edited = app.workbench.editedFiles
        guard !edited.isEmpty, !unsavedAnswered else { return .terminateNow }
        let system = Self.systemQuit
        var answered: Bool?
        Task {
            let answer = await runSheet(UnsavedChanges.alert(edited, quitting: true))
            let done = await UnsavedChanges.settle(edited, answer)
            answered = done ? await UnsavedChanges.written(edited) : false
            if answered == true, !system { unsavedAnswered = true; NSApp.terminate(nil) }
        }
        // Logging out or shutting down: a cancel here cancels it, so the answer is waited for in place, events and
        // the main actor's tasks served meanwhile. Not `terminateLater`: until its reply AppKit runs a modal mode in
        // which the main actor's tasks don't run, so the question could never be asked.
        guard system else { return .terminateCancel }   // ⌘Q: asked in a sheet, then quit again
        while answered == nil {
            if let e = NSApp.nextEvent(matching: .any, until: .now + 0.1, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // the daemon keeps sessions alive
    func applicationWillTerminate(_ n: Notification) {
        main?.leaveFocusMode()
        EditorArea.saveLayouts()   // a tab moved in the last half second
        app.client?.flush()   // writes are queued: the last layout or state set goes out before the process ends
    }

    /// Folders dropped on the Dock icon or opened with `open -a Kelp <path>` become projects; files open as tabs.
    /// What opens Kelp waits for the projects and the last workspace to be on screen.
    func application(_ sender: NSApplication, open urls: [URL]) {
        if pendingOpens != nil { pendingOpens? += urls; return }
        for u in urls where u.scheme == "kelp" { KelpLinks(app).handle(u) }
        app.workbench.open(files: urls.filter(\.isFileURL))
    }

    /// Right-click on the Dock icon: the agents waiting for you, like Mail's dock menu offers what's new.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for s in AttentionQueue(app).sessions {
            let place = app.worktree(s.worktreeId)?.displayName ?? ""
            let state = s.status == .waiting ? String(localized: "needs you") : String(localized: "finished")
            let i = m.add("\(app.catalog.displayName(s)) — \(state) · \(place)") { [app] in NSApp.activate(); app.workbench.focus(session: s.id) }
            i.image = app.catalog.icon(s.agent, size: 16)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.add(String(localized: "New Workspace")) { [app] in NSApp.activate(); app.workbench.newWorkspace() }
        return m
    }

    /// Finished agents read at a glance (`Glances`): timed only while one is unread, so no clock runs the rest of the time.
    private var glances = Glances()
    private var glanceClock: Timer?
    private static func readOnSight(_ s: Session) -> Bool { s.unread && (s.status == .done || (s.status == .exited && !s.endedWithError)) }
    private func timeGlances(_ on: Bool) {
        glanceClock?.invalidate()
        glanceClock = nil
        glances = Glances()
        guard on else { return }
        // Main run loop: AppKit runs the timer on the main thread.
        glanceClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.trackGlances() } }
    }
    private func trackGlances() {
        let w = main?.window, e = app.workbench.editor
        let front = NSApp.isActive && w?.isKeyWindow == true && w?.occlusionState.contains(.visible) == true && e != nil
        let app = app
        let mark = glances.tick(front: front, shown: e?.visibleSessions ?? [], readable: { app.session($0).map(Self.readOnSight) ?? false },
                                unread: { app.session($0)?.unread == true }, now: Date())
        for sid in mark {
            Task { [weak self] in if await self?.app.call(SessionMarkRead(id: sid)) == nil { self?.glances.failed(sid) } }   // try again later
        }
    }

    // MARK: menu
    /// A menu item (the menu bar's or the sidebar's Add Project menu) runs the command its identifier names.
    @objc func runCommand(_ sender: Any?) {
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        app.extensions.command(id)?.run([:])
    }

    private(set) lazy var archivedMenu = ArchivedMenu(app: app)

    /// The command's menu item: its identifier is the command id (Settings › Keyboard, `validateMenuItem`).
    func item(_ c: CommandSpec) -> NSMenuItem {
        let i = NSMenuItem(title: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        i.target = self; i.identifier = NSUserInterfaceItemIdentifier(c.id)
        if let k = c.key.flatMap(KeySpec.init) { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags }
        return i
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does; Focus Mode is ticked while it's on; Stop needs something running;
    /// the file commands need a file.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "workbench.toggleSidebar": item.title = main.sidebarShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case "workbench.toggleInspector": item.title = main.inspectorShown ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case "workbench.toggleFocusMode": item.state = main.inFocusMode ? .on : .off
        case "power.keepAwake": item.state = app.settings.string("power.keepAwake") == "always" ? .on : .off
        case "scripts.run", "scripts.test", "scripts.edit": return app.workbench.workspaceId != nil
        case "scripts.stop": return app.scripts.canStop
        // Off elsewhere, so a terminal still gets their keys.
        case "editor.runFile", "editor.testAtCursor", "editor.format": return app.workbench.editor?.focusedContent?.fileURL != nil
        case "editor.addNextOccurrence", "editor.selectAllOccurrences", "editor.moveLinesUp", "editor.moveLinesDown",
             "editor.copyLinesUp", "editor.copyLinesDown", "editor.deleteLines", "editor.toggleComment", "editor.indent", "editor.outdent":
            return CodeEditor.focused != nil
        default: break
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
        track(owner: self) { [app] in app.worktrees } changed: { [weak self] _ in Task { await self?.reload() } }
    }
    private func reload() async {
        let r = await app.tryCall(WorktreeList(archived: true))
        archived = (r.value ?? []).filter(\.archived); failed = r.error
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let failed { menu.addItem(withTitle: failed, action: nil, keyEquivalent: "").isEnabled = false; return }
        guard !archived.isEmpty else { menu.addItem(withTitle: String(localized: "None"), action: nil, keyEquivalent: "").isEnabled = false; return }
        for w in archived.sorted(by: { $0.createdAt > $1.createdAt }) {
            menu.add("\(w.displayName) — \(app.projectName(w.repoId) ?? "")") { [app] in WorkspaceActions(app).unarchive(w.id) }
        }
    }
}
