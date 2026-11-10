import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The Run menu and the title bar's run chip: the project's commands — what its files offer (`run.detect`: package.json,
/// Makefile, compose…) and `.kelp.yaml`'s — each in a tab of its own, opened behind what you're doing; when it ends, a
/// banner says how, with the way to its output. ⌘R runs what last ran in the project (`run.last.<project>` in UIState),
/// else lists the choices; ⌘U the tests, ⌘. stops. A .kelp.yaml's commands run only after you trust the file.
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
    /// run.start calls on their way: a page printed before the call's answer is a run's too (kept, not opened).
    var starting = 0
    /// The run chip's name, which the Run menu opens under.
    weak var anchor: NSView?

    // MARK: menu

    /// The Run menu's fixed items are commands (scripts.run, .test, .stop, .edit); the project's other commands fill in when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let wid = app.workbench.workspaceId
        // Between the two separators: setup and the commands other than run/test.
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
        if let wid { Task { await load(wid) } }   // next time it's current
    }

    /// `asked`: for Run, which says why it can't (a banner); the menu's refresh in the background stays quiet.
    @discardableResult func load(_ wid: String, asked: Bool = false) async -> ScriptsList.Result? {
        let request = ScriptsList(worktreeId: wid)
        guard let result = asked ? await app.call(request) : await app.quiet(request) else { return nil }
        if state.kelp[wid] != result.scripts { state.kelp[wid] = result.scripts }
        let file = Self.shortName(result.file)
        if state.kelpFile[wid] != file { state.kelpFile[wid] = file }
        setupCommand[wid] = result.setup
        return result
    }

    /// Something started here in this workspace is still running (Run › Stop, the chip's ■).
    var canStop: Bool { app.workbench.workspaceId.map { !running(in: $0).isEmpty } ?? false }

    @objc private func runNamed(_ item: NSMenuItem) { (item.representedObject as? String).map(run) }

    // MARK: running

    /// ⌘R ("run"): what last ran in the project, else .kelp.yaml's run, else the list. ⌘U ("test"): .kelp.yaml's test,
    /// else the files' tests. Without either, the focused file's language's.
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
                await start(wid, test.id, RunStart(worktreeId: wid, id: test.id))
                return
            }
            if name == "run", found?.options.isEmpty == false {
                choose()
                return
            }
            // Nothing in the project: ⌘R runs the focused file, ⌘U its test at the cursor, when its language says how.
            if let tab = app.workbench.editor?.focusedContent, ["run", "test"].contains(name),
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

    /// A .kelp.yaml command, trusted first if the file isn't yet. Its run (or one picked in the list) becomes ⌘R's.
    /// `pullRequest`: the folder holds that PR's code, which the file's trust doesn't cover; it's asked about every time.
    func runKelp(
        _ wid: String, _ name: String, _ info: ScriptsList.Result, remember: Bool = false, pullRequest: Int? = nil
    ) async {
        if let pullRequest {
            guard ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] == nil, await askPullRequest(pullRequest, info)
            else { return }
        }
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

    /// A new workspace's setup, when its .kelp.yaml has one that waits for the file's trust (asked here first).
    func setup(_ wid: String, pullRequest: Int?) async {
        if let info = await load(wid), info.setup != nil { await runKelp(wid, "setup", info, pullRequest: pullRequest) }
    }

    /// Run File / Test at Cursor: the file's language's `run` / `test`, run like the project's commands. Languages come
    /// from extensions the user installed, so there's no trust question.
    func runFile(_ tab: TabContent, _ name: String) {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        watch()
        Task {
            guard let cmd = await tab.command(name) else { return }
            let title = "\(name) \(tab.title)"
            await start(wid, title, SessionCreate(worktreeId: wid, command: cmd, title: title))
        }
    }

    /// Again: start over, like Xcode's Run (the last run's tab gives way to the new one). False when it didn't start.
    @discardableResult func start<M: RPCMethod>(_ wid: String, _ choice: String, _ method: M) async -> Bool
    where M.Result == Session {
        watch()
        let same = running(in: wid).filter { app.session($0).flatMap(self.choice(of:)) == choice }
        // Put away in the Run menu: started over, it stays there.
        let hidden = same.contains(where: app.workbench.isHidden)
        for sid in same {
            state.active[sid] = nil
            await app.call(SessionKill(id: sid))
            app.workbench.closeTab(uri: TabURI.session(sid), remember: false)
        }
        starting += 1
        let made = await app.call(method)
        starting -= 1
        guard let session = made else { return false }
        let sid = session.id
        state.active[sid] = RunState.Run(workspace: wid, choice: choice, url: state.early.removeValue(forKey: sid))
        app.upsert(session)
        if hidden {
            hide(sid)
            return true
        }
        // Below what you're doing, like a console; the keys stay where they were.
        if wid == app.workbench.workspaceId {
            app.workbench.open(TabURI.session(sid), split: .down, workspace: wid, focus: false)
        } else {
            app.workbench.openInBackground(TabURI.session(sid), workspace: wid)
        }
        return true
    }

    func stop() {
        guard let wid = app.workbench.workspaceId else { return }
        for sid in running(in: wid) { Task { await app.call(SessionKill(id: sid)) } }
    }

    /// The runs still going in a workspace, the first started first.
    func running(in wid: String) -> [String] {
        app.sessions.filter { $0.worktreeId == wid && $0.status != .exited && choice(of: $0) != nil }.sorted {
            $0.createdAt < $1.createdAt
        }.map(\.id)
    }

    /// What a session runs, when it's one of its workspace's choices: started here, before Kelp restarted, or by `kelp`
    /// and agents (run.start, scripts.run) — known by its command line.
    func choice(of session: Session) -> String? {
        if let run = state.active[session.id] { return run.choice }
        guard session.agent == "custom", let wid = session.worktreeId, let line = session.argv.last else { return nil }
        if let option = state.found[wid]?.options.first(where: {
            ($0.folder.isEmpty ? $0.command : "cd \(ShellQuote.word($0.folder)) && \($0.command)") == line
        }) {
            return option.id
        }
        return state.kelp[wid]?.first { $0.command == line }.map { "kelp:" + $0.name }
    }

    /// A page a session printed (event.devserver): a run's waits on the chip for a click. Any other's (Jupyter) in the
    /// workspace on screen opens beside it, the keys staying where they are: the page comes while you may be typing.
    func served(_ event: DevServerEvent) {
        if state.active[event.session] != nil {
            state.active[event.session]?.url = event.url
        } else if starting > 0 {
            state.early[event.session] = event.url
        } else if event.worktree == app.workbench.workspaceId {
            app.workbench.open(event.url, split: .right, workspace: event.worktree, focus: false)
        }
    }

    /// The first time a project's commands would run: everything trusting the file allows (commands, the agents and links
    /// a new workspace gets, the prompts it puts in agents' mouths), and whose it is.
    private func askTrust(_ info: ScriptsList.Result) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Run this project's commands?")
        alert.informativeText =
            String(
                localized:
                    "\((info.file as NSString).abbreviatingWithTildeInPath) asks Kelp to run these as you, in this folder. "
            )
            + String(
                localized:
                    "Trust it only if you know where this project comes from. Kelp asks again if the file changes.")
        alert.accessoryView = Self.trustText(info)
        alert.addButton(withTitle: String(localized: "Trust and Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    private func askPullRequest(_ number: Int, _ info: ScriptsList.Result) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Run setup on pull request #\(number)?")
        alert.informativeText =
            String(
                localized:
                    "Its code comes from whoever wrote the pull request: what setup installs or builds can run their scripts as you. "
            )
            + String(localized: "Skip it to read the code first.")
        alert.accessoryView = Self.trustText(info)
        alert.addButton(withTitle: String(localized: "Run Setup"))
        alert.addButton(withTitle: String(localized: "Skip"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// A project's commands file as the menu names it: from its first folder that starts with a dot (`.conductor/settings.toml`,
    /// `.codex/environments/environment.toml`), else its own name (`conductor.json`).
    static func shortName(_ path: String) -> String {
        let parts = path.split(separator: "/").suffix(3)
        return (parts.firstIndex { $0.hasPrefix(".") }.map { parts[$0...] } ?? parts.suffix(1)).joined(separator: "/")
    }

    /// The file's effects as the file spells them, scrollable when long.
    static func trustText(_ info: ScriptsList.Result) -> NSView {
        var lines: [String] = []
        if let setup = info.setup { lines.append("setup: \(setup)") }
        for script in info.scripts { lines.append("\(script.name): \(script.command)") }
        if !info.tabs.isEmpty { lines.append("tabs: " + info.tabs.joined(separator: ", ")) }
        if !info.shared.isEmpty { lines.append("shared: " + info.shared.joined(separator: ", ")) }
        if let command = info.issueCommand { lines.append("issueCommand: \(command)") }
        for (name, recipe) in info.recipes.sorted(by: { $0.key < $1.key }) { lines.append("recipe.\(name): \(recipe)") }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: min(220, CGFloat(max(lines.count, 1)) * 16 + 8))
        scroll.drawsBackground = false
        if let text = scroll.documentView as? NSTextView {
            text.string = lines.joined(separator: "\n")
            text.isEditable = false
            text.drawsBackground = false
            text.font = .uiMono(11)
        }
        return scroll
    }

    /// How a run ended, said once: failed (with its output a click away), finished, or — on a host — cut off with the
    /// program still running there (its tab offers Reconnect).
    private func watch() {
        let app = self.app
        guard !watching else { return }
        watching = true
        track(owner: self) {
            app.sessions.filter { $0.status == .exited }
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

    /// The project's .kelp.yaml in a tab (started with the keys it knows, if there isn't one).
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
            // Made only when there's none: one that's there fails to be made, and opens as it is.
            _ = await app.tryCall(FilesCreate(path: path, text: keys))
            app.workbench.open(TabURI.file(path))
        }
    }
}
