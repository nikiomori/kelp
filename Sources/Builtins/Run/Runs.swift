import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The Run menu and the title bar's run chip. They run the project's commands, both what its files offer
/// (`run.detect`: package.json, Makefile, compose…) and `.kelp.yaml`'s, each in a tab of its own, opened behind what
/// you're doing. When a command ends, a banner says how, with the way to its output. ⌘R runs what last ran in the
/// project (`run.last.<project>` in UIState), else lists the choices; ⌘U runs the tests, and ⌘. stops. A .kelp.yaml's
/// commands run only after you trust the file.
@MainActor
final class Runs: NSObject, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }
    let state = RunState()
    private var setupCommand: [String: String] = [:]
    private var watching = false
    /// How many run.start calls are still on their way. A page printed before the call's answer belongs to a run too,
    /// so it is kept, not opened.
    var starting = 0
    /// The run chip's name, which the Run menu opens under.
    weak var anchor: NSView?

    // MARK: menu

    /// The Run menu's fixed items are commands (scripts.run, .test, .stop, .edit); the project's other commands fill
    /// in when the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let wid = app.workbench.workspaceId
        // Between the two separators go setup and the commands other than run and test.
        let seps = menu.items.indices.filter { menu.items[$0].isSeparatorItem }
        if seps.count >= 2 {
            for index in stride(from: seps[1] - 1, to: seps[0], by: -1) { menu.removeItem(at: index) }
        }
        var at = (seps.first ?? 2) + 1
        let extra = (wid.flatMap { state.kelp[$0] } ?? []).filter { !["run", "test"].contains($0.name) }.map(\.name)
        for name in (wid.flatMap { setupCommand[$0] } != nil ? ["setup"] : []) + extra {
            let item = NSMenuItem(
                title: name.prefix(1).uppercased() + name.dropFirst(), action: #selector(runNamed(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.insertItem(item, at: at)
            at += 1
        }
        if let wid { Task { await load(wid) } }   // so the menu is current next time
    }

    /// `asked` is for Run, which says in a banner why it can't run; the menu's refresh in the background stays quiet.
    @discardableResult func load(_ wid: String, asked: Bool = false) async -> ScriptsList.Result? {
        let request = ScriptsList(worktreeId: wid)
        guard let result = asked ? await app.call(request) : await app.quiet(request) else { return nil }
        if state.kelp[wid] != result.scripts { state.kelp[wid] = result.scripts }
        let file = Self.shortName(result.file)
        if state.kelpFile[wid] != file { state.kelpFile[wid] = file }
        setupCommand[wid] = result.setup
        return result
    }

    /// Whether something started here in this workspace is still running (Run › Stop, the chip's ■).
    var canStop: Bool { app.workbench.workspaceId.map { !running(in: $0).isEmpty } ?? false }

    @objc private func runNamed(_ item: NSMenuItem) { (item.representedObject as? String).map(run) }

    // MARK: running

    /// ⌘R ("run") runs what last ran in the project, else .kelp.yaml's run, else shows the list. ⌘U ("test") runs
    /// .kelp.yaml's test, else the tests the files define. Without either, it uses the focused file's language's
    /// command.
    func run(_ name: String) {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        watch()
        Task { [weak self] in
            guard let self, let info = await load(wid, asked: true) else { return }
            let scripts = state.kelp[wid] ?? []
            if name == "setup" || scripts.contains(where: { $0.name == name }), name != "run" || remembered(wid) == nil
            {
                await runKelp(wid, name, info)
                return
            }
            if name == "run", let last = remembered(wid), await start(choice: last, in: wid) { return }
            let found = await detect(wid)
            if name == "test", let test = found?.options.first(where: { $0.kind == "test" && $0.missing == nil }) {
                await start(wid, test.id, app.workbench.sized(RunStart(worktreeId: wid, id: test.id), split: .down))
                return
            }
            if name == "run", found?.options.isEmpty == false {
                choose()
                return
            }
            // With nothing in the project, ⌘R runs the focused file and ⌘U its test at the cursor, when the file's
            // language says how.
            if let tab = app.workbench.focusedContent, ["run", "test"].contains(name),
                tab.language?[command: name] != nil
            {
                runFile(tab, name)
                return
            }
            Banner.show(
                String(
                    localized: "This project has no “\(name)” command. Add one to .kelp.yaml (\(name): the command)."),
                action: (String(localized: "Edit Commands"), { [weak self] in self?.edit() }))
        }
    }

    /// Runs a .kelp.yaml command, trusting the file first if it isn't trusted yet (`KelpFile`). Its run (or one picked
    /// in the list) becomes ⌘R's.
    func runKelp(_ wid: String, _ name: String, _ info: ScriptsList.Result, remember: Bool = false) async {
        guard await KelpFile(app: app).trusted(wid, info) else { return }
        if remember || name == "run" { self.remember("kelp:" + name, in: wid) }
        await start(wid, "kelp:" + name, app.workbench.sized(ScriptsRun(worktreeId: wid, name: name), split: .down))
    }

    /// Starts a .kelp.yaml command for a layout template (`ProjectRuns.run`), after its trust was already asked. It
    /// starts the way Run starts a command (an earlier copy of it ends first, and the run is kept as the workspace's),
    /// but the template decides where its tab goes.
    func runForTemplate(_ wid: String, _ name: String) async -> Session? {
        await launch(wid, "kelp:" + name, app.workbench.sized(ScriptsRun(worktreeId: wid, name: name)), tab: false)
    }

    /// Run File / Test at Cursor: the file's language's `run` / `test`, run like the project's commands. Languages
    /// come from extensions the user installed, so there's no trust question.
    func runFile(_ tab: TabContent, _ name: String) {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        watch()
        Task {
            guard let cmd = await tab.command(name) else { return }
            let title = "\(name) \(tab.title)"
            await start(
                wid, title,
                app.workbench.sized(SessionCreate(worktreeId: wid, command: cmd, title: title), split: .down))
        }
    }

    /// Runs a choice again, starting over like Xcode's Run (the last run's tab gives way to the new one). Returns
    /// false when it didn't start.
    @discardableResult func start<M: RPCMethod>(_ wid: String, _ choice: String, _ method: M) async -> Bool
    where M.Result == Session {
        await launch(wid, choice, method) != nil
    }

    /// Does what `start` does, and returns the session it started. `tab` false leaves the tab to the caller; a run put
    /// away in the Run menu has none.
    private func launch<M: RPCMethod>(_ wid: String, _ choice: String, _ method: M, tab: Bool = true) async -> Session?
    where M.Result == Session {
        watch()
        let same = running(in: wid).filter { app.session($0).flatMap(self.choice(of:)) == choice }
        // A run put away in the Run menu stays there when it's started over.
        let hidden = same.contains(where: app.workbench.isHidden)
        for sid in same {
            state.active[sid] = nil
            await app.call(SessionKill(id: sid))
            app.workbench.closeTab(uri: TabURI.session(sid), remember: false)
        }
        starting += 1
        let made = await app.call(method)
        starting -= 1
        guard let session = made else { return nil }
        let sid = session.id
        state.active[sid] = RunState.Run(workspace: wid, choice: choice, url: state.early.removeValue(forKey: sid))
        app.upsert(session)
        if hidden {
            hide(sid)
            return session
        }
        guard tab else { return session }
        // The tab opens below what you're doing, like a console, and the keys stay where they were.
        if wid == app.workbench.workspaceId {
            app.workbench.open(TabURI.session(sid), split: .down, workspace: wid, focus: false)
        } else {
            app.workbench.openInBackground(TabURI.session(sid), workspace: wid)
        }
        return session
    }

    func stop() {
        guard let wid = app.workbench.workspaceId else { return }
        for sid in running(in: wid) { Task { await app.call(SessionKill(id: sid)) } }
    }

    /// The runs still going in a workspace, the first one started first.
    func running(in wid: String) -> [String] {
        app.sessions.filter { $0.worktreeId == wid && $0.status != .exited && choice(of: $0) != nil }.sorted {
            $0.createdAt < $1.createdAt
        }.map(\.id)
    }

    /// What a session runs, when it's one of its workspace's choices: started here, before Kelp restarted, or by `kelp`
    /// and agents (run.start, scripts.run). Such a session is known by its command line.
    func choice(of session: Session) -> String? {
        if let run = state.active[session.id] { return run.choice }
        guard session.agent == Session.customAgent, let wid = session.worktreeId, let line = session.argv.last else {
            return nil
        }
        if let option = state.found[wid]?.options.first(where: {
            ($0.folder.isEmpty ? $0.command : "cd \(ShellQuote.word($0.folder)) && \($0.command)") == line
        }) {
            return option.id
        }
        return state.kelp[wid]?.first { $0.command == line }.map { "kelp:" + $0.name }
    }

    /// Handles a page a session printed (event.devserver). A run's page waits on the chip for a click. Any other
    /// session's page (Jupyter) in the workspace on screen opens beside it, and the keys stay where they are, because
    /// the page comes while you may be typing.
    func served(_ event: DevServerEvent) {
        if state.active[event.session] != nil {
            state.active[event.session]?.url = event.url
        } else if starting > 0 {
            state.early[event.session] = event.url
        } else if event.worktree == app.workbench.workspaceId {
            app.workbench.open(event.url, split: .right, workspace: event.worktree, focus: false)
        }
    }

    /// A project's commands file as the menu names it: from its first folder that starts with a dot
    /// (`.conductor/settings.toml`, `.codex/environments/environment.toml`), else its own name (`conductor.json`).
    static func shortName(_ path: String) -> String {
        let parts = path.split(separator: "/").suffix(3)
        return (parts.firstIndex { $0.hasPrefix(".") }.map { parts[$0...] } ?? parts.suffix(1)).joined(separator: "/")
    }

    /// Says once how a run ended: failed (with its output a click away), finished, or, on a host, cut off with the
    /// program still running there (its tab offers Reconnect).
    private func watch() {
        let app = self.app
        guard !watching else { return }
        watching = true
        // Only the runs going on are followed, not every session that ever ended, on every agent's news.
        track(owner: self) { [state] in
            state.active.keys.sorted().compactMap { app.session($0) }.filter { $0.status == .exited }
        } changed: { [weak self] ended in
            guard let self else { return }
            for session in ended {
                guard let run = state.active.removeValue(forKey: session.id) else { continue }
                let name = "“\(label(run.choice, in: run.workspace))”"
                let id = session.id
                let show: (String, @MainActor @Sendable () -> Void) = (
                    String(localized: "Show Output"), { app.workbench.focus(session: id) }
                )
                if session.connectionLost {
                    Banner.show(
                        String(localized: "The connection to the host dropped. \(name) keeps running there."),
                        action: show)
                } else if session.endedWithError, let code = session.exitCode {
                    let reason = "(exit code \(code))"
                    Banner.show(String(localized: "\(name) failed \(reason)"), style: .error, action: show)
                } else {
                    Banner.show(String(localized: "\(name) finished"), action: show)
                }
            }
        }
    }

    /// Opens the project's .kelp.yaml in a tab, starting one with the keys it knows if there isn't one.
    func edit() {
        guard let worktree = app.worktree(app.workbench.workspaceId) else {
            NSSound.beep()
            return
        }
        let path = (app.repo(worktree.repoId)?.path ?? worktree.path) + "/.kelp.yaml"
        let keys = """
            # Kelp's Run menu runs these in the workspace's folder (Kelp asks before the first run).
            # run: npm run dev
            # test: npm test
            # lint: npm run lint
            # script.deploy: ./scripts/deploy.sh
            # setup: npm install          (also runs in each new worktree)

            """
        Task {
        // The file is made only when there's none. Making one that's there fails, and it opens as it is.
            _ = await app.tryCall(FilesCreate(path: path, text: keys))
            app.workbench.open(TabURI.file(path))
        }
    }
}
