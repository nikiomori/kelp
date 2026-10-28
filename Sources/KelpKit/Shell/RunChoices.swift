import AppKit
import Core
import DesignKit
import WorkbenchKit

/// What can run in each workspace and what runs now: the run chip and the Run list follow it.
@MainActor @Observable
final class RunState {
    struct Run: Equatable {
        /// "kelp:<name>" for a .kelp.yaml command, an option's id (run.detect) or a file's run.
        var workspace: String, choice: String
        /// The page it serves, once it printed one: opened by a click, never by itself.
        var url: String?
    }
    /// Workspace → what its files offer.
    var found: [String: RunDetect.Result] = [:]
    /// Workspace → its .kelp.yaml's commands.
    var kelp: [String: [ScriptsList.Script]] = [:]
    /// Session → what it runs.
    var active: [String: Run] = [:]
    /// Pages printed before run.start answered with their session.
    @ObservationIgnored var early: [String: String] = [:]
}

extension ScriptsMenu {
    // MARK: the choices

    /// What ran last in the workspace's project (its desks share it).
    func remembered(_ wid: String) -> String? { project(wid).flatMap { app.uiState["run.last.\($0)"]?.string } }
    func remember(_ choice: String, in wid: String) { project(wid).map { app.uiState["run.last.\($0)"] = .string(choice) } }
    private func project(_ wid: String) -> String? { app.worktree(wid)?.repoId }

    /// What the workspace's files offer, read again (on a remote host: one ssh call). Quiet: the list says what it has.
    @discardableResult func detect(_ wid: String) async -> RunDetect.Result? {
        guard let r = await app.quiet(RunDetect(worktreeId: wid)) else { return state.found[wid] }
        if state.found[wid] != r { state.found[wid] = r }
        return r
    }

    /// Runs a choice and keeps it as the project's: false when it's gone (the file no longer has it).
    @discardableResult func start(choice: String, in wid: String) async -> Bool {
        if choice.hasPrefix("kelp:") {
            let name = String(choice.dropFirst(5))
            guard let info = await load(wid), info.scripts.contains(where: { $0.name == name }) else { return false }
            await runKelp(wid, name, info, remember: true)
            return true
        }
        remember(choice, in: wid)
        return await start(wid, choice, RunStart(worktreeId: wid, id: choice))
    }

    /// What the chip and the list call a choice: "dev", "frontend › dev".
    func label(_ choice: String, in wid: String) -> String {
        if choice.hasPrefix("kelp:") { return String(choice.dropFirst(5)) }
        guard let o = state.found[wid]?.options.first(where: { $0.id == choice }) else { return choice.split(separator: "|").last.map(String.init) ?? choice }
        return o.folder.isEmpty ? o.name : "\((o.folder as NSString).lastPathComponent) › \(o.name)"
    }

    /// What ⌘R would run in the workspace now, and whether it's only a guess (nothing ran in the project yet).
    func current(_ wid: String) -> (choice: String, guess: Bool)? {
        if let s = running(in: wid).first.flatMap(app.session), let c = choice(of: s) { return (c, false) }
        if let last = remembered(wid) { return (last, false) }
        if state.kelp[wid]?.contains(where: { $0.name == "run" }) == true { return ("kelp:run", false) }
        return state.found[wid]?.guess.map { ($0, true) }
    }

    /// What the empty workspace and the "+" menu offer to run, as the chip names it: its label, its command, and whether
    /// it's only a guess (then ⌘R lists the choices instead of running it).
    struct Offer: Equatable { var choice: String, label: String, command: String?, guess: Bool }
    func offer(_ wid: String) -> Offer? {
        current(wid).map { c in
            let command = c.choice.hasPrefix("kelp:") ? state.kelp[wid]?.first { "kelp:" + $0.name == c.choice }?.command
                : state.found[wid]?.options.first { $0.id == c.choice }?.command
            return Offer(choice: c.choice, label: label(c.choice, in: wid), command: command, guess: c.guess)
        }
    }

    /// The Run list under the chip: shown at once with what's known, filled in as the files are read again.
    func choose() {
        guard let wid = app.workbench.workspaceId else { NSSound.beep(); return }
        if popover.isShown { popover.performClose(nil); return }
        Task { [weak self] in
            guard let self else { return }
            if state.found[wid] == nil { await detect(wid) } else { Task { await self.detect(wid) } }
            await load(wid)
            let vc = RunPicker(app: app, workspace: wid)
            popover.behavior = .transient
            popover.contentViewController = vc
            let at = anchor?.window != nil ? anchor : app.workbench.window?.window?.contentView
            guard let at else { return }
            popover.show(relativeTo: at === anchor ? at.bounds : NSRect(x: at.bounds.midX, y: at.bounds.maxY - 40, width: 1, height: 1), of: at,
                         preferredEdge: .maxY)
        }
    }

    /// The page a run serves, beside what you're doing.
    func openPage(_ sid: String) {
        guard let r = state.active[sid], let url = r.url else { return }
        app.workbench.open(url, split: .right, workspace: r.workspace, focus: false)
    }

    /// The list's sections: dependencies to install first, .kelp.yaml's commands, then each file's, by folder.
    func sections(_ wid: String) -> [RunPicker.Section] {
        let options = state.found[wid]?.options ?? []
        let mark = current(wid)?.choice
        let live = Dictionary(running(in: wid).compactMap { sid in app.session(sid).flatMap(choice(of:)).map { ($0, sid) } }) { a, _ in a }
        func row(_ id: String, _ name: String, _ command: String, missing: String? = nil) -> RunPicker.Row {
            RunPicker.Row(id: id, name: name, command: command, missing: missing, session: live[id], url: live[id].flatMap { state.active[$0]?.url },
                          key: id == mark ? "⌘R" : nil)
        }
        var out: [RunPicker.Section] = []
        let installs = options.filter { $0.kind == "install" }
        if !installs.isEmpty {
            out.append(.init(title: String(localized: "Dependencies"), rows: installs.map {
                row($0.id, $0.folder.isEmpty ? String(localized: "Install") : String(localized: "Install in \($0.folder)"), $0.command, missing: $0.missing)
            }))
        }
        if let kelp = state.kelp[wid], !kelp.isEmpty { out.append(.init(title: ".kelp.yaml", rows: kelp.map { row("kelp:" + $0.name, $0.name, $0.command) })) }
        var groups: [(key: String, rows: [RunPicker.Row])] = []
        for o in options where o.kind != "install" {
            let key = o.folder.isEmpty ? o.source : "\(o.folder) · \(o.source)"
            let r = row(o.id, o.name, [o.command, o.detail].compactMap { $0 }.joined(separator: " · "), missing: o.missing)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].rows.append(r) } else { groups.append((key, [r])) }
        }
        return out + groups.map { .init(title: $0.key, rows: $0.rows) }
    }
}
