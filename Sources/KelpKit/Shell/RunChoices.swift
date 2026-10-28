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
    /// Workspace → the ports its sessions listen on, as last read for the Run menu.
    @ObservationIgnored var ports: [String: [PortsList.Port]] = [:]
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
    /// What the chip, the banners and "Run …" call a choice: the command itself ("make dev", "web › npm run dev"), which
    /// says what runs it where a bare "dev" wouldn't; a long one cut.
    func label(_ choice: String, in wid: String) -> String {
        if choice.hasPrefix("kelp:") {
            return state.kelp[wid]?.first { "kelp:" + $0.name == choice }.map { Self.short($0.command) } ?? String(choice.dropFirst(5))
        }
        guard let o = state.found[wid]?.options.first(where: { $0.id == choice }) else { return choice.split(separator: "|").last.map(String.init) ?? choice }
        return (o.folder.isEmpty ? "" : "\((o.folder as NSString).lastPathComponent) › ") + Self.short(o.command)
    }

    /// A command as one short line (32 characters), whole in tips.
    static func short(_ s: String) -> String { s.count > 32 ? s.prefix(31).trimmingCharacters(in: .whitespaces) + "…" : s }

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
            if let ports = await app.quiet(PortsList(worktreeId: wid)) { adopt(ports, wid) }
            let m = menu(wid)
            // 4 pt under the chip, as the title bar's other menus; without the chip (focus mode), near the window's top.
            if let a = anchor, a.window != nil { m.popUp(positioning: nil, at: NSPoint(x: 0, y: a.bounds.height + 4), in: a) }
            else if let v = app.workbench.window?.window?.contentView {
                m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX - 120, y: v.bounds.maxY - 40), in: v)
            }
        }
    }

    /// The ports the workspace's sessions listen on: a run's page found again (it printed it before Kelp restarted), and
    /// the servers an agent or a terminal started, for the menu's first section.
    private func adopt(_ ports: [PortsList.Port], _ wid: String) {
        state.ports[wid] = ports
        for p in ports {
            guard let s = app.session(p.session), let c = choice(of: s), state.active[s.id]?.url == nil else { continue }
            state.active[s.id] = RunState.Run(workspace: wid, choice: c, url: "http://localhost:\(p.port)")
        }
    }

    private func menu(_ wid: String) -> NSMenu {
        let m = NSMenu()
        // Servers this menu didn't start (an agent's dev server, one typed in a terminal): before starting a second one.
        // ssh is a remote project's forwarding, not a server.
        let elsewhere = (state.ports[wid] ?? []).filter { p in p.command != "ssh" && app.session(p.session).map { choice(of: $0) == nil } ?? false }
        if !elsewhere.isEmpty {
            m.addItem(.sectionHeader(title: String(localized: "Already Running")))
            for p in elsewhere { server(p, in: m, wid) }
        }
        let sections = sections(wid), rows = sections.flatMap(\.rows)
        if rows.count <= Self.flat {
            for s in sections {
                m.addItem(.sectionHeader(title: s.title))
                for r in s.rows { item(r, in: m, wid) }
            }
        } else {
            // Too many for one screen: the few that matter here, then every file's in a submenu of its own.
            // Mixed files and folders: each shows as its command, its folder beside it.
            for r in top(rows, wid) { item(r, in: m, wid, asCommand: true) }
            m.addItem(.separator())
            m.addItem(.sectionHeader(title: String(localized: "All Commands")))
            // A file of the workspace's own folder has its submenu; a subfolder (api, web) one for all its files.
            var groups: [(title: String, folder: Bool, sections: [Section])] = []
            for s in sections {
                let key = s.folder.isEmpty ? s.title : s.folder
                if let i = groups.firstIndex(where: { $0.title == key }) { groups[i].sections.append(s) }
                else { groups.append((key, !s.folder.isEmpty, [s])) }
            }
            for g in groups { submenu(g.title, folder: g.folder, g.sections, in: m, wid) }
        }
        if sections.isEmpty { m.addItem(withTitle: String(localized: "Nothing to run found"), action: nil, keyEquivalent: "").isEnabled = false }
        m.addItem(.separator())
        m.add(String(localized: "Edit Commands…"), symbol: "pencil") { [weak self] in self?.edit() }
        return m
    }

    /// One choice: its name, what it adds under it (a script's body, a target's description, a service's port — never the
    /// command that only repeats the name), its whole command as the tip.
    private func item(_ r: Row, in m: NSMenu, _ wid: String, asCommand: Bool = false) {
        let i = m.add(r.name, key: r.current ? "r" : "") { [weak self] in
            guard let self else { return }
            Task { r.install ? await self.start(wid, r.id, RunStart(worktreeId: wid, id: r.id)) : await self.start(choice: r.id, in: wid) }
        }
        icon(i, r.file)
        i.state = r.current ? .on : .off
        i.toolTip = [r.detail, r.command].compactMap { $0 }.joined(separator: "\n")
        let port = r.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let detail = asCommand && r.detail == r.command ? nil : r.detail
        let said = r.running ? [String(localized: "Running"), port].compactMap { $0 }.joined(separator: " · ")
            : r.missing.map { String(localized: "\($0) isn't installed") } ?? detail.map(Self.oneLine)
        if #available(macOS 14.4, *), let said { i.subtitle = said }
        guard asCommand else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: Self.short(r.command), attributes: [.font: font])
        if !r.folder.isEmpty {
            title.append(NSAttributedString(string: "  " + r.folder, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        i.attributedTitle = title
    }

    /// "Makefile ▸" with its commands, or "api ▸" with each of its files' commands under the file's name.
    private func submenu(_ title: String, folder: Bool, _ sections: [Section], in m: NSMenu, _ wid: String) {
        let sub = NSMenu()
        for s in sections {
            if folder { sub.addItem(.sectionHeader(title: s.file)) }
            for r in s.rows { item(r, in: sub, wid) }
        }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if folder { image(i, .symbol("folder")) } else if let r = sections.first?.rows.first { icon(i, r.file) }
        m.addItem(i)
        m.setSubmenu(sub, for: i)
        let n = sections.reduce(0) { $0 + $1.rows.count }
        if #available(macOS 14.4, *) { i.subtitle = String(localized: "Commands: \(n)") }
    }

    /// A server an agent or a terminal started here: what it is (the command the files name, when the agent's background
    /// task runs it; else the program), who started it and its port. A click opens its page; with ⌥, it stops.
    private func server(_ p: PortsList.Port, in m: NSMenu, _ wid: String) {
        let s = app.session(p.session)
        let agent = s?.agent.flatMap { id in ["shell", "custom"].contains(id) ? nil : app.catalog.all.first { $0.id == id } }
        let tasks = s?.background ?? []
        let what = state.found[wid]?.options.first { o in tasks.contains { $0.contains(o.command) } }?.name ?? p.command
        let url = "http://localhost:\(p.port)"
        let open = m.add(what) { [weak self] in self?.app.workbench.open(url, split: .right, workspace: wid, focus: false) }
        image(open, agent.flatMap { app.catalog.icon($0.id) } ?? .symbol("terminal"))
        open.toolTip = String(localized: "Open \(url)")
        if #available(macOS 14.4, *) { open.subtitle = "\(agent?.name ?? String(localized: "Terminal")) · :\(p.port)" }
        let stop = m.add(String(localized: "Stop \(what)")) { [weak self] in
            Task { await self?.app.call(PortsStop(worktreeId: wid, pid: Int(p.pid))) }
        }
        image(stop, .symbol("stop.circle"))
        stop.isAlternate = true
        stop.keyEquivalentModifierMask = .option
    }

    /// The icon of the file a choice comes from, as Files shows it: what runs it (npm, Python, make, Docker) at a glance,
    /// and the file's section it sits in.
    private func icon(_ i: NSMenuItem, _ file: String) { image(i, app.fileIcons.image((file as NSString).lastPathComponent)) }

    /// An item's image, kept on macOS 27, whose menus hide the images an item doesn't ask to show.
    private func image(_ i: NSMenuItem, _ image: NSImage?) {
        i.image = image
        #if compiler(>=6.4)   // the macOS 27 SDK
        if #available(macOS 27, *) { i.preferredImageVisibility = .visible }
        #endif
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
        /// run.detect's kind (run, test, build, lint, other) and the file it comes from.
        var kind = "other", file = ""
        /// Where it runs inside the workspace ("" its own folder).
        var folder = ""
    }

    /// `folder` and `file` for a file's section ("" folder: the workspace's own); a title of its own otherwise.
    struct Section { var title: String, rows: [Row], folder = "", file = "" }

    /// The menu's sections: dependencies to install first, .kelp.yaml's commands, then each file's, by folder.
    func sections(_ wid: String) -> [Section] {
        let options = state.found[wid]?.options ?? []
        let mark = current(wid)?.choice
        let live = Dictionary(running(in: wid).compactMap { sid in app.session(sid).flatMap(choice(of:)).map { ($0, sid) } }) { a, _ in a }
        func row(_ id: String, _ name: String, _ command: String, detail: String? = nil, missing: String? = nil, install: Bool = false,
                 kind: String = "other", file: String, folder: String = "") -> Row {
            Row(id: id, name: name, command: command, detail: detail, missing: missing, running: live[id] != nil,
                url: live[id].flatMap { state.active[$0]?.url }, current: id == mark, install: install, kind: kind, file: file,
                folder: folder)
        }
        var out: [Section] = []
        let installs = options.filter { $0.kind == "install" }
        if !installs.isEmpty {
            out.append(.init(title: String(localized: "Dependencies"), rows: installs.map {
                let name = $0.folder.isEmpty ? String(localized: "Install") : String(localized: "Install in \($0.folder)")
                return row($0.id, name, $0.command, detail: $0.command, missing: $0.missing, install: true, file: $0.source, folder: $0.folder)
            }))
        }
        if let kelp = state.kelp[wid], !kelp.isEmpty {
            let kinds = ["run": "run", "test": "test", "build": "build", "lint": "lint"]
            out.append(.init(title: ".kelp.yaml", rows: kelp.map {
                row("kelp:" + $0.name, $0.name, $0.command, detail: $0.command, kind: kinds[$0.name] ?? "other", file: ".kelp.yaml")
            }))
        }
        var groups: [(key: String, folder: String, file: String, rows: [Row])] = []
        for o in options where o.kind != "install" {
            let key = o.folder.isEmpty ? o.source : "\(o.folder) · \(o.source)"
            // "make dev", "swift run": the name already says it.
            let plain = o.command == o.name || o.command.hasSuffix(" " + o.name)
            let r = row(o.id, o.name, o.command, detail: o.detail ?? (plain ? nil : o.command), missing: o.missing, kind: o.kind,
                        file: o.source, folder: o.folder)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].rows.append(r) } else { groups.append((key, o.folder, o.source, [r])) }
        }
        return out + groups.map { .init(title: $0.key, rows: $0.rows, folder: $0.folder, file: $0.file) }
    }
}
