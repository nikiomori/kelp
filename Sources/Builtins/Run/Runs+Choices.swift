import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What can run in each workspace and what runs now. The run chip and the Run list follow it.
@MainActor @Observable
final class RunState {
    struct Run: Equatable {
        /// "kelp:<name>" for a .kelp.yaml command, an option's id (run.detect), or a file's run.
        var workspace: String, choice: String
        /// The page the run serves, once it printed one. It opens on a click, never by itself.
        var url: String?
    }
    /// What each workspace's files offer, by workspace.
    var found: [String: RunDetect.Result] = [:]
    /// Each workspace's .kelp.yaml commands, and the file they come from when it's another tool's
    /// (`.conductor/settings.toml`).
    var kelp: [String: [ScriptsList.Script]] = [:]
    var kelpFile: [String: String] = [:]
    /// What each session runs, by session.
    var active: [String: Run] = [:]
    /// Pages printed before run.start answered with their session.
    @ObservationIgnored var early: [String: String] = [:]
    /// Runs put away in the Run menu during this run of Kelp (`hidden` adds the kept list). The sidebar and the tabs
    /// follow it.
    var hidden: Set<String> = []
    /// The ports each workspace's sessions listen on, as last read for the Run menu.
    @ObservationIgnored var ports: [String: [PortsList.Port]] = [:]
}

extension Runs {
    // MARK: the choices

    /// What ran last in the workspace's project, which its workspaces share.
    func remembered(_ wid: String) -> String? { project(wid).flatMap { app.uiState["run.last.\($0)"]?.string } }
    func remember(_ choice: String, in wid: String) {
        project(wid).map { app.uiState["run.last.\($0)"] = .string(choice) }
    }

    private func project(_ wid: String) -> String? { app.worktree(wid)?.repoId }

    /// Reads again what the workspace's files offer (on a remote host, in one ssh call). It is quiet, because the list
    /// says what it has.
    @discardableResult func detect(_ wid: String) async -> RunDetect.Result? {
        guard let result = await app.quiet(RunDetect(worktreeId: wid)) else { return state.found[wid] }
        if state.found[wid] != result { state.found[wid] = result }
        return result
    }

    /// Runs a choice and keeps it as the project's choice. Returns false when the choice is gone (the file no longer
    /// has it).
    @discardableResult func start(choice: String, in wid: String) async -> Bool {
        if choice.hasPrefix("kelp:") {
            let name = String(choice.dropFirst(5))
            guard let info = await load(wid), info.scripts.contains(where: { $0.name == name }) else { return false }
            await runKelp(wid, name, info, remember: true)
            return true
        }
        remember(choice, in: wid)
        return await start(wid, choice, app.workbench.sized(RunStart(worktreeId: wid, id: choice), split: .down))
    }

    /// What the chip, the banners and "Run …" call a choice: the command itself ("make dev", "web › npm run dev"),
    /// which says what runs where a bare "dev" wouldn't. A long command is cut.
    func label(_ choice: String, in wid: String) -> String {
        if choice.hasPrefix("kelp:") {
            return state.kelp[wid]?.first { "kelp:" + $0.name == choice }.map { Self.short($0.command) }
                ?? String(choice.dropFirst(5))
        }
        guard let option = state.found[wid]?.options.first(where: { $0.id == choice }) else {
            return choice.split(separator: "|").last.map(String.init) ?? choice
        }
        return (option.folder.isEmpty ? "" : "\((option.folder as NSString).lastPathComponent) › ")
            + Self.short(option.command)
    }

    /// A command as one short line (32 characters); tips show it whole.
    static func short(_ command: String) -> String {
        command.count > 32 ? command.prefix(31).trimmingCharacters(in: .whitespaces) + "…" : command
    }

    /// What ⌘R would run in the workspace now, and whether it's only a guess (nothing ran in the project yet).
    func current(_ wid: String) -> (choice: String, guess: Bool)? {
        if let session = running(in: wid).first.flatMap(app.session), let picked = choice(of: session) {
            return (picked, false)
        }
        if let last = remembered(wid) { return (last, false) }
        if state.kelp[wid]?.contains(where: { $0.name == "run" }) == true { return ("kelp:run", false) }
        return state.found[wid]?.guess.map { ($0, true) }
    }

    /// What the empty workspace and the "+" menu offer to run, named as the chip names it: its label, its command, and
    /// whether it's only a guess (then ⌘R lists the choices instead of running it).
    struct Offer: Equatable { var choice: String, label: String, command: String?, guess: Bool }
    func offer(_ wid: String) -> Offer? {
        current(wid).map { pick in
            let command =
                pick.choice.hasPrefix("kelp:")
                ? state.kelp[wid]?.first { "kelp:" + $0.name == pick.choice }?.command
                : state.found[wid]?.options.first { $0.id == pick.choice }?.command
            return Offer(choice: pick.choice, label: label(pick.choice, in: wid), command: command, guess: pick.guess)
        }
    }

    /// The run chip's run action and its list; none while the project offers nothing to run.
    func choices(_ wid: String) -> [NewTabChoices.Action] {
        guard let offer = offer(wid) else { return [] }
        let choose = NewTabChoices.key("scripts.choose", app, default: "ctrl+cmd+r"),
            run = offer.guess ? nil : NewTabChoices.key("scripts.run", app, default: "cmd+r")
        return [
            NewTabChoices.Action(
                title: String(localized: "Run \(offer.label)"), symbol: "play", key: run, help: offer.command
            ) {
                Task { await self.start(choice: offer.choice, in: wid) }
            },
            NewTabChoices.Action(title: String(localized: "Choose What to Run…"), symbol: "list.bullet", key: choose) {
                self.choose()
            }
        ]
    }

    /// Shows the Run menu under the chip, like Xcode's scheme menu: a section per file, what ⌘R runs checked, and what
    /// runs now said under its name. It shows with what's known, and the files are read again for next time (at once
    /// if nothing is known yet).
    func choose(from button: NSView? = nil) {
        guard let wid = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if state.found[wid] == nil { await detect(wid) } else { Task { await self.detect(wid) } }
            await load(wid)
            if let ports = await app.quiet(PortsList(worktreeId: wid)) { adopt(ports, wid) }
            let runMenu = menu(wid)
        // 4 pt under the chip, as the title bar's other menus are. Without the chip (in focus mode), near the
        // window's top.
            if let below = button ?? anchor, below.window != nil {
                runMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: below.bounds.height + 4), in: below)
            } else if let content = app.workbench.windowContent {
                runMenu.popUp(
                    positioning: nil, at: NSPoint(x: content.bounds.midX - 120, y: content.bounds.maxY - 40),
                    in: content)
            }
        }
    }

    /// Takes the ports the workspace's sessions listen on, for the menu's first section. They find a run's page again
    /// (when it printed its address before Kelp restarted), and the servers an agent or a terminal started.
    private func adopt(_ ports: [PortsList.Port], _ wid: String) {
        state.ports[wid] = ports
        for port in ports {
            guard let session = app.session(port.session), let picked = choice(of: session),
                state.active[session.id]?.url == nil
            else {
                continue
            }
            state.active[session.id] = RunState.Run(
                workspace: wid, choice: picked, url: "http://localhost:\(port.port)")
        }
    }

    struct Row {
        var id, name, command: String
        var detail: String?, missing: String?, url: String?
        var running = false, current = false, install = false
        /// The command's session while it runs.
        var session: String?
        /// run.detect's kind (run, test, build, lint, other), the file it comes from, and where it runs ("" is the
        /// workspace's folder).
        var kind = "other", file = "", folder = ""
        /// What the command is for, from the fields above (`Runs.purpose`), set once the row is made.
        var purpose = Purpose.other
    }

    /// Every command the menu offers: .kelp.yaml's first, then those from the project's files (its own folder's
    /// first), with which of them runs now and what ⌘R runs.
    func rows(_ wid: String) -> [Row] {
        let mark = current(wid)?.choice
        let live = Dictionary(
            running(in: wid).compactMap { sid in app.session(sid).flatMap(choice(of:)).map { ($0, sid) } }
        ) { a, _ in a }
        let kinds = ["run": "run", "test": "test", "build": "build", "lint": "lint"]
        let kelp = (state.kelp[wid] ?? []).map {
            Row(
                id: "kelp:" + $0.name, name: $0.name, command: $0.command, kind: kinds[$0.name] ?? "other",
                file: state.kelpFile[wid] ?? ".kelp.yaml")
        }
        let found = (state.found[wid]?.options ?? []).map { option in
            Row(
                id: option.id, name: option.kind == "install" ? String(localized: "Install") : option.name,
                command: option.command,
                detail: option.detail,
                missing: option.missing, kind: option.kind, file: option.source, folder: option.folder)
        }
        return (kelp + found).map { row in
            var row = row
            row.url = live[row.id].flatMap { state.active[$0]?.url }
            row.running = live[row.id] != nil
            row.session = live[row.id]
            row.current = row.id == mark
            row.install = row.kind == "install"
            row.purpose = Self.purpose(row)
            return row
        }
    }
}
