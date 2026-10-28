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
    func remember(_ choice: String, in wid: String) {
        guard let p = project(wid) else { return }
        app.uiState["run.last.\(p)"] = .string(choice)
        app.uiState["run.recent.\(p)"] = .array(([choice] + recent(wid).filter { $0 != choice }).prefix(5).map(JSONValue.string))
    }
    /// What ran lately in the project, the last first (five at most): the top of a long Run menu.
    func recent(_ wid: String) -> [String] { project(wid).map { app.uiState.strings("run.recent.\($0)") } ?? [] }
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

    /// The Run menu under the chip, as Xcode's scheme menu: a section per file, what ⌘R runs checked, what runs now said
    /// under its name. Shown with what's known; the files are read again for next time (at once if nothing is known yet).
    func choose() {
        guard let wid = app.workbench.workspaceId else { NSSound.beep(); return }
        Task { [weak self] in
            guard let self else { return }
            if state.found[wid] == nil { await detect(wid) } else { Task { await self.detect(wid) } }
            await load(wid)
            let m = menu(wid)
            // 4 pt under the chip, as the title bar's other menus; without the chip (focus mode), near the window's top.
            if let a = anchor, a.window != nil { m.popUp(positioning: nil, at: NSPoint(x: 0, y: a.bounds.height + 4), in: a) }
            else if let v = app.workbench.window?.window?.contentView {
                m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX - 120, y: v.bounds.maxY - 40), in: v)
            }
        }
    }

    private func menu(_ wid: String) -> NSMenu {
        let m = NSMenu()
        let sections = sections(wid), rows = sections.flatMap(\.rows)
        if rows.count <= Self.flat {
            for s in sections {
                m.addItem(.sectionHeader(title: s.title))
                for r in s.rows { item(r, in: m, wid) }
            }
        } else {
            // Too many for one screen: the few that matter here, then every file's in a submenu of its own.
            for r in top(rows, wid) { item(r, in: m, wid) }
            m.addItem(.separator())
            m.addItem(.sectionHeader(title: String(localized: "All Commands")))
            for s in sections {
                let sub = NSMenu()
                for r in s.rows { item(r, in: sub, wid) }
                let i = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
                i.image = .symbol("doc.text")
                m.addItem(i)
                m.setSubmenu(sub, for: i)
                if #available(macOS 14.4, *) { i.subtitle = String(localized: "Commands: \(s.rows.count)") }
            }
        }
        if sections.isEmpty { m.addItem(withTitle: String(localized: "Nothing to run found"), action: nil, keyEquivalent: "").isEnabled = false }
        m.addItem(.separator())
        m.add(String(localized: "Edit Commands…"), symbol: "pencil") { [weak self] in self?.edit() }
        return m
    }

    /// One choice: its name, what it adds under it (a script's body, a target's description, a service's port — never the
    /// command that only repeats the name), its whole command as the tip.
    private func item(_ r: Row, in m: NSMenu, _ wid: String) {
        let i = m.add(r.name, symbol: Self.symbol(r), key: r.current ? "r" : "") { [weak self] in
            guard let self else { return }
            Task { r.install ? await self.start(wid, r.id, RunStart(worktreeId: wid, id: r.id)) : await self.start(choice: r.id, in: wid) }
        }
        i.state = r.current ? .on : .off
        i.toolTip = [r.detail, r.command].compactMap { $0 }.joined(separator: "\n")
        let port = r.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let said = r.running ? [String(localized: "Running"), port].compactMap { $0 }.joined(separator: " · ")
            : r.missing.map { String(localized: "\($0) isn't installed") } ?? r.detail.map(Self.oneLine)
        if #available(macOS 14.4, *), let said { i.subtitle = said }
    }

    /// Up to this many, the menu lists them all by file; more, and it shows `top` and a submenu per file.
    static let flat = 12

    /// What a long menu starts with: dependencies to install, what runs now, what ⌘R runs, what ran lately, then the
    /// likeliest server, tests, build and lint the files offer. Eight at most.
    private func top(_ rows: [Row], _ wid: String) -> [Row] {
        let byId = Dictionary(rows.map { ($0.id, $0) }) { a, _ in a }
        let guess = state.found[wid]?.guess
        var ids = rows.filter { $0.install || $0.running || $0.current }.map(\.id) + recent(wid) + [guess].compactMap { $0 }
        ids += ["test", "build", "lint"].compactMap { k in rows.first { $0.kind == k && $0.missing == nil }?.id }
        var seen = Set<String>()
        return ids.filter { byId[$0] != nil && seen.insert($0).inserted }.prefix(8).compactMap { byId[$0] }
    }

    /// A description as one short line: its first line, cut at 60 characters (the tip has it whole).
    static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return first.count > 60 ? first.prefix(59).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    /// The page a run serves, beside what you're doing.
    func openPage(_ sid: String) {
        guard let r = state.active[sid], let url = r.url else { return }
        app.workbench.open(url, split: .right, workspace: r.workspace, focus: false)
    }

    struct Row {
        var id, name, command: String, detail: String?, missing: String?, running: Bool, url: String?, current: Bool, install: Bool
        /// run.detect's kind (run, test, build, lint, other); a compose service's row is a container.
        var kind = "other", container = false
    }

    /// What a command does, at a glance, in the symbols Kelp gives commit types: ▶ a server, a flask for tests, a hammer
    /// for builds; by its name for the rest (publish, clean, migrate…); a terminal when nothing says. ▶ in a circle: it runs now.
    static func symbol(_ r: Row) -> String {
        let n = r.name.lowercased()
        let named: [(words: [String], symbol: String)] = [
            (["publish", "release", "deploy", "ship"], "paperplane"), (["clean"], "trash"), (["format", "fmt"], "paintbrush"),
            (["migrate", "seed", "db"], "cylinder"), (["doc"], "doc.text"), (["install", "setup", "bootstrap", "deps"], "arrow.down.circle")
        ]
        if r.running { return "play.circle.fill" }
        if r.install { return "arrow.down.circle" }
        switch r.kind {
        case "run": return "play"
        case "test": return "flask"
        case "build": return "hammer"
        case "lint": return n.hasPrefix("format") || n.hasPrefix("fmt") ? "paintbrush" : "checklist"
        default: break
        }
        if r.container { return "shippingbox" }
        return named.first { $0.words.contains(where: n.hasPrefix) }?.symbol ?? "terminal"
    }
    struct Section { var title: String, rows: [Row] }

    /// The menu's sections: dependencies to install first, .kelp.yaml's commands, then each file's, by folder.
    func sections(_ wid: String) -> [Section] {
        let options = state.found[wid]?.options ?? []
        let mark = current(wid)?.choice
        let live = Dictionary(running(in: wid).compactMap { sid in app.session(sid).flatMap(choice(of:)).map { ($0, sid) } }) { a, _ in a }
        func row(_ id: String, _ name: String, _ command: String, detail: String? = nil, missing: String? = nil, install: Bool = false,
                 kind: String = "other", container: Bool = false) -> Row {
            Row(id: id, name: name, command: command, detail: detail, missing: missing, running: live[id] != nil,
                url: live[id].flatMap { state.active[$0]?.url }, current: id == mark, install: install, kind: kind, container: container)
        }
        var out: [Section] = []
        let installs = options.filter { $0.kind == "install" }
        if !installs.isEmpty {
            out.append(.init(title: String(localized: "Dependencies"), rows: installs.map {
                let name = $0.folder.isEmpty ? String(localized: "Install") : String(localized: "Install in \($0.folder)")
                return row($0.id, name, $0.command, detail: $0.command, missing: $0.missing, install: true)
            }))
        }
        if let kelp = state.kelp[wid], !kelp.isEmpty {
            let kinds = ["run": "run", "test": "test", "build": "build", "lint": "lint"]
            out.append(.init(title: ".kelp.yaml", rows: kelp.map {
                row("kelp:" + $0.name, $0.name, $0.command, detail: $0.command, kind: kinds[$0.name] ?? "other")
            }))
        }
        var groups: [(key: String, rows: [Row])] = []
        for o in options where o.kind != "install" {
            let key = o.folder.isEmpty ? o.source : "\(o.folder) · \(o.source)"
            // "make dev", "swift run": the name already says it.
            let plain = o.command == o.name || o.command.hasSuffix(" " + o.name)
            let r = row(o.id, o.name, o.command, detail: o.detail ?? (plain ? nil : o.command), missing: o.missing, kind: o.kind,
                        container: o.source.contains("compose") && o.kind != "run")
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].rows.append(r) } else { groups.append((key, [r])) }
        }
        return out + groups.map { .init(title: $0.key, rows: $0.rows) }
    }
}
