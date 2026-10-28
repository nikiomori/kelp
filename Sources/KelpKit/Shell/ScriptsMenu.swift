import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The Run menu and the title bar's run chip: the project's commands — what its files offer (`run.detect`: package.json,
/// Makefile, compose…) and `.kelp.yaml`'s — each in a tab of its own, opened behind what you're doing; when it ends, a
/// banner says how, with the way to its output. ⌘R runs what last ran in the project (`run.last.<project>` in UIState),
/// else lists the choices; ⌘U the tests, ⌘. stops. A .kelp.yaml's commands run only after you trust the file.
@MainActor
package final class ScriptsMenu: NSObject, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init() }
    let state = RunState()
    private var setupCommand: [String: String] = [:]
    private var watching = false
    /// run.start calls on their way: a page printed before the call's answer is a run's too (kept, not opened).
    var starting = 0
    /// The run chip, which the list opens under.
    weak var anchor: NSView?
    let popover = NSPopover()

    // MARK: menu

    /// The Run menu's fixed items are commands (scripts.run, .test, .stop, .edit); the project's other commands fill in when it opens.
    package func menuNeedsUpdate(_ m: NSMenu) {
        let wid = app.workbench.workspaceId
        // Between the two separators: setup and the commands other than run/test.
        let seps = m.items.indices.filter { m.items[$0].isSeparatorItem }
        if seps.count >= 2 { for i in stride(from: seps[1] - 1, to: seps[0], by: -1) { m.removeItem(at: i) } }
        var at = (seps.first ?? 2) + 1
        let extra = (wid.flatMap { state.kelp[$0] } ?? []).filter { !["run", "test"].contains($0.name) }.map(\.name)
        for name in (wid.flatMap { setupCommand[$0] } != nil ? ["setup"] : []) + extra {
            let i = NSMenuItem(title: name.prefix(1).uppercased() + name.dropFirst(), action: #selector(runNamed(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = name
            m.insertItem(i, at: at); at += 1
        }
        if let wid { Task { await load(wid) } }   // next time it's current
    }

    /// `asked`: for Run, which says why it can't (a banner); the menu's refresh in the background stays quiet.
    @discardableResult func load(_ wid: String, asked: Bool = false) async -> ScriptsList.Result? {
        let m = ScriptsList(worktreeId: wid)
        guard let r = asked ? await app.call(m) : await app.quiet(m) else { return nil }
        if state.kelp[wid] != r.scripts { state.kelp[wid] = r.scripts }
        setupCommand[wid] = r.setup
        return r
    }

    /// Something started here in this workspace is still running (Run › Stop, the chip's ■).
    var canStop: Bool { app.workbench.workspaceId.map { !running(in: $0).isEmpty } ?? false }

    @objc private func runNamed(_ i: NSMenuItem) { (i.representedObject as? String).map(run) }

    // MARK: running

    /// ⌘R ("run"): what last ran in the project, else .kelp.yaml's run, else the list. ⌘U ("test"): .kelp.yaml's test,
    /// else the files' tests. Without either, the focused file's language's.
    func run(_ name: String) {
        guard let wid = app.workbench.workspaceId else { NSSound.beep(); return }
        watch()
        Task { [weak self] in
            guard let self, let info = await load(wid, asked: true) else { return }
            let scripts = state.kelp[wid] ?? []
            if name == "setup" || scripts.contains(where: { $0.name == name }), name != "run" || remembered(wid) == nil {
                await runKelp(wid, name, info)
                return
            }
            if name == "run", let last = remembered(wid), await start(choice: last, in: wid) { return }
            let found = await detect(wid)
            if name == "test", let t = found?.options.first(where: { $0.kind == "test" && $0.missing == nil }) {
                await start(wid, t.id, RunStart(worktreeId: wid, id: t.id))
                return
            }
            if name == "run", found?.options.isEmpty == false { choose(); return }
            // Nothing in the project: ⌘R runs the focused file, ⌘U its test at the cursor, when its language says how.
            if let t = app.workbench.editor?.focusedContent, ["run", "test"].contains(name), t.language?[command: name] != nil {
                runFile(t, name); return
            }
            Banner.show(String(localized: "This project has no “\(name)” command. Add one to .kelp.yaml (\(name): the command)."),
                        action: (String(localized: "Edit Commands"), { [weak self] in self?.edit() }))
        }
    }

    /// A .kelp.yaml command, trusted first if the file isn't yet. Its run (or one picked in the list) becomes ⌘R's.
    func runKelp(_ wid: String, _ name: String, _ info: ScriptsList.Result, remember: Bool = false) async {
        if !info.trusted {
            // A snapshot run takes clicks and keys from its environment (DevAids): anyone could start one that presses
            // Trust, so that window never trusts anything.
            guard ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] == nil else { return }
            guard await askTrust(info) else { return }
            // The digest of the text shown: a file changed since (an agent, a pull) isn't trusted unseen.
            guard await app.call(ScriptsTrust(worktreeId: wid, digest: info.digest)) != nil else { return }
        }
        if remember || name == "run" { self.remember("kelp:" + name, in: wid) }
        await start(wid, "kelp:" + name, ScriptsRun(worktreeId: wid, name: name))
    }

    /// Run File / Test at Cursor: the file's language's `run` / `test`, run like the project's commands. Languages come
    /// from extensions the user installed, so there's no trust question.
    package func runFile(_ t: TabContent, _ name: String) {
        guard let wid = app.workbench.workspaceId else { NSSound.beep(); return }
        watch()
        Task {
            guard let cmd = await t.command(name) else { return }
            let title = "\(name) \(t.title)"
            await start(wid, title, SessionCreate(worktreeId: wid, command: cmd, title: title))
        }
    }

    /// Again: start over, like Xcode's Run (the last run's tab gives way to the new one). False when it didn't start.
    @discardableResult func start<M: RPCMethod>(_ wid: String, _ choice: String, _ method: M) async -> Bool where M.Result == Session {
        watch()
        for sid in running(in: wid) where app.session(sid).flatMap(self.choice(of:)) == choice {
            state.active[sid] = nil
            await app.call(SessionKill(id: sid))
            app.workbench.closeTab(uri: TabURI.session(sid))
        }
        starting += 1
        let s = await app.call(method)
        starting -= 1
        guard let sid = s?.id else { return false }
        state.active[sid] = RunState.Run(workspace: wid, choice: choice, url: state.early.removeValue(forKey: sid))
        await app.refresh()
        // Below what you're doing, like a console; the keys stay where they were.
        if wid == app.workbench.workspaceId { app.workbench.open(TabURI.session(sid), split: .down, workspace: wid, focus: false) }
        else { app.workbench.window?.editors.openInBackground(TabURI.session(sid), workspace: wid) }
        return true
    }

    func stop() {
        guard let wid = app.workbench.workspaceId else { return }
        for sid in running(in: wid) { Task { await app.call(SessionKill(id: sid)) } }
    }

    /// The runs still going in a workspace, the first started first.
    func running(in wid: String) -> [String] {
        app.sessions.filter { $0.worktreeId == wid && $0.status != .exited && choice(of: $0) != nil }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }

    /// What a session runs, when it's one of its workspace's choices: started here, before Kelp restarted, or by `kelp`
    /// and agents (run.start, scripts.run) — known by its command line.
    func choice(of s: Session) -> String? {
        if let r = state.active[s.id] { return r.choice }
        guard s.agent == "custom", let wid = s.worktreeId, let line = s.argv.last else { return nil }
        if let o = state.found[wid]?.options.first(where: { ($0.folder.isEmpty ? $0.command : "cd \(RemoteHost.quote($0.folder)) && \($0.command)") == line }) {
            return o.id
        }
        return state.kelp[wid]?.first { $0.command == line }.map { "kelp:" + $0.name }
    }

    /// A page a session printed (event.devserver): a run's waits on the chip for a click; any other's (Jupyter) opens beside.
    func served(_ e: DevServerEvent) -> Bool {
        if state.active[e.session] != nil { state.active[e.session]?.url = e.url; return true }
        guard starting > 0 else { return false }
        state.early[e.session] = e.url
        return true
    }

    /// The first time a project's commands would run: everything trusting the file allows (commands, the agents and links
    /// a new workspace gets, the prompts it puts in agents' mouths), and whose it is.
    private func askTrust(_ info: ScriptsList.Result) async -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "Run this project's commands?")
        a.informativeText = String(localized: "\((info.file as NSString).abbreviatingWithTildeInPath) asks Kelp to run these as you, in the workspace's folder. ")
            + String(localized: "Trust it only if you know where this project comes from. Kelp asks again if the file changes.")
        a.accessoryView = Self.trustText(info)
        a.addButton(withTitle: String(localized: "Trust and Run")); a.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(a) == .alertFirstButtonReturn
    }

    /// The file's effects as the file spells them, scrollable when long.
    static func trustText(_ info: ScriptsList.Result) -> NSView {
        var lines: [String] = []
        if let s = info.setup { lines.append("setup: \(s)") }
        for s in info.scripts { lines.append("\(s.name): \(s.command)") }
        if !info.tabs.isEmpty { lines.append("tabs: " + info.tabs.joined(separator: ", ")) }
        if !info.shared.isEmpty { lines.append("shared: " + info.shared.joined(separator: ", ")) }
        if let c = info.issueCommand { lines.append("issueCommand: \(c)") }
        for (k, v) in info.recipes.sorted(by: { $0.key < $1.key }) { lines.append("recipe.\(k): \(v)") }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 10))
        text.string = lines.joined(separator: "\n")
        text.isEditable = false
        text.drawsBackground = false
        text.font = .uiMono(11)
        text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(220, CGFloat(max(lines.count, 1)) * 16 + 8)))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    /// How a run ended, said once: failed (with its output a click away), finished, or — on a host — cut off with the
    /// program still running there (its tab offers Reconnect).
    private func watch() {
        let app = self.app
        guard !watching else { return }
        watching = true
        track(owner: self) { app.sessions.filter { $0.status == .exited } } changed: { [weak self] ended in
            guard let self else { return }
            for s in ended {
                guard let r = state.active.removeValue(forKey: s.id) else { continue }
                let name = "“\(label(r.choice, in: r.workspace))”"
                let id = s.id
                let show: (String, @MainActor @Sendable () -> Void) = (String(localized: "Show Output"), { app.workbench.focus(session: id) })
                if s.connectionLost {
                    Banner.show(String(localized: "The connection to the host dropped. \(name) keeps running there."), action: show)
                } else if s.summary.hasPrefix("Ended with an error") {
                    Banner.show(String(localized: "\(name) failed \(s.summary.replacingOccurrences(of: "Ended with an error ", with: ""))"),
                                style: .error, action: show)
                } else { Banner.show(String(localized: "\(name) finished"), action: show) }
            }
        }
    }

    /// The project's .kelp.yaml in a tab (started with the keys it knows, if there isn't one).
    func edit() {
        guard let w = app.worktree(app.workbench.workspaceId) else { NSSound.beep(); return }
        let path = (app.repo(w.repoId)?.path ?? w.path) + "/.kelp.yaml"
        let keys = """
            # Kelp's Run menu runs these in the workspace's folder (Kelp asks before the first run).
            # run: npm run dev
            # test: npm test
            # lint: npm run lint
            # script.deploy: ./scripts/deploy.sh
            # setup: npm install          (also runs in each new worktree)

            """
        Task {
            // Made only when there's none: one that's there fails to be made, and opens as it is.
            _ = await app.tryCall(FilesCreate(path: path, text: keys))
            app.workbench.open(TabURI.file(path))
        }
    }
}
