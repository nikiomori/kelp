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
    /// Runs put away in the Run menu this run of Kelp (`ScriptsMenu.isHidden` reads the kept list too): the sidebar and
    /// the tabs follow it.
    var hidden: Set<String> = []
    /// Workspace → the ports its sessions listen on, as last read for the Run menu.
    @ObservationIgnored var ports: [String: [PortsList.Port]] = [:]
}

extension ScriptsMenu {
    // MARK: the choices

    /// What ran last in the workspace's project (its desks share it).
    func remembered(_ wid: String) -> String? { project(wid).flatMap { app.uiState["run.last.\($0)"]?.string } }
    func remember(_ choice: String, in wid: String) { project(wid).map { app.uiState["run.last.\($0)"] = .string(choice) } }

    // MARK: hidden runs

    /// Runs whose tab was put away in the Run menu: they keep running, the menu shows them (`run.hidden` in UIState, so a
    /// restarted Kelp doesn't bring their tabs back).
    /// The sessions the sidebar lists: a run hidden in the Run menu is there, not in the sidebar.
    var shown: [Session] { app.sessions.filter { !isHidden($0.id) } }
    func isHidden(_ sid: String) -> Bool { state.hidden.contains(sid) || app.uiState.strings("run.hidden").contains(sid) }
    func hide(_ sid: String) {
        state.hidden.insert(sid)
        let live = app.uiState.strings("run.hidden").filter { app.session($0).map { $0.status != .exited } ?? false }
        app.uiState["run.hidden"] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        app.workbench.hideTab(uri: TabURI.session(sid))
    }
    /// Its tab again, below what you're doing, and the keys in it.
    func show(_ sid: String) {
        state.hidden.remove(sid)
        app.uiState["run.hidden"] = .array(app.uiState.strings("run.hidden").filter { $0 != sid }.map(JSONValue.string))
        app.workbench.open(TabURI.session(sid), split: .down, workspace: app.session(sid)?.worktreeId, focus: true)
    }

    /// How a run's tab stands out among terminals: its purpose's symbol in colour (green ▶ for a server) and a glow of
    /// that colour, the port it serves after its name. nil for any other session.
    func look(_ s: Session) -> (icon: NSImage?, glow: NSColor?, port: String?)? {
        guard let wid = s.worktreeId, let c = choice(of: s), var r = rows(wid).first(where: { $0.id == c }) else { return nil }
        r.running = false   // its purpose's mark, not the menu's "running" circle
        let (symbol, color) = Self.glyph(r)
        let port = state.active[s.id]?.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        return (Self.tinted(symbol, color), color == .secondaryLabelColor ? nil : color, port)
    }
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

    /// The Run menu: what's already running that it didn't start, then the project's commands by what they do — Run,
    /// Tests, Build & Check, Deploy — a line each, a coloured symbol of its purpose, where it comes from in grey; the rest
    /// under More, by file. A description and the whole command are the tip.
    private func menu(_ wid: String) -> NSMenu {
        let m = NSMenu()
        // Servers this menu didn't start (an agent's dev server, one typed in a terminal): before starting a second one.
        // ssh is a remote project's forwarding, not a server.
        let elsewhere = (state.ports[wid] ?? []).filter { p in p.command != "ssh" && app.session(p.session).map { choice(of: $0) == nil } ?? false }
        if !elsewhere.isEmpty {
            m.addItem(.sectionHeader(title: String(localized: "Already Running")))
            for p in elsewhere { server(p, in: m, wid) }
        }
        let rows = rows(wid), by = Dictionary(grouping: rows, by: Self.purpose), rest = by[.other] ?? []
        // Where they come from, in a column after the longest name.
        let column = Self.column(rows.filter { Self.purpose($0) != .other || rest.count <= 3 }.map(\.name) + [String(localized: "More")])
        for p in Purpose.allCases where p != .other {
            guard let some = by[p] else { continue }
            m.addItem(.sectionHeader(title: p.title))
            for r in some { item(r, in: m, wid, column: column) }
        }
        if rest.count > 3 {
            let sub = NSMenu(), inSub = Self.column(rest.map(\.name))
            var file = ""
            for r in rest {
                let from = r.folder.isEmpty ? r.file : "\(r.folder) · \(r.file)"
                if from != file { sub.addItem(.sectionHeader(title: from)); file = from }
                item(r, in: sub, wid, column: inSub)
            }
            let more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            more.attributedTitle = Self.title(String(localized: "More"), note: "\(rest.count)", column: column)
            image(more, .symbol("ellipsis.circle"))
            m.addItem(more)
            m.setSubmenu(sub, for: more)
        } else if !rest.isEmpty {
            m.addItem(.sectionHeader(title: Purpose.other.title))
            for r in rest { item(r, in: m, wid, column: column) }
        }
        if rows.isEmpty { m.addItem(withTitle: String(localized: "Nothing to run found"), action: nil, keyEquivalent: "").isEnabled = false }
        m.addItem(.separator())
        m.add(String(localized: "Edit Commands…"), symbol: "pencil") { [weak self] in self?.edit() }
        return m
    }

    /// One command on one line: its purpose's symbol, its name, where it comes from ("make", "npm · web") — or its port
    /// while it runs, what's missing when it can't. ⌘R and a check for what ⌘R runs.
    private func item(_ r: Row, in m: NSMenu, _ wid: String, column: CGFloat) {
        // Running: a click shows its output (its tab may be hidden here), ⌥ stops it; ⌘R or ▶ starts it over.
        let i = m.add(r.name, key: r.current ? "r" : "") { [weak self] in
            guard let self else { return }
            if let sid = r.session { show(sid); return }
            Task { r.install ? await self.start(wid, r.id, RunStart(worktreeId: wid, id: r.id)) : await self.start(choice: r.id, in: wid) }
        }
        defer {
            if let sid = r.session {
                let stop = m.add(String(localized: "Stop \(r.name)")) { [weak self] in Task { await self?.app.call(SessionKill(id: sid)) } }
                image(stop, Self.tinted("stop.circle.fill", .systemRed))
                stop.keyEquivalent = i.keyEquivalent   // an alternate pairs with its item by key: ⌥ added to ⌘R, or ⌥ alone
                stop.keyEquivalentModifierMask = i.keyEquivalent.isEmpty ? .option : [.command, .option]
                stop.isAlternate = true
            }
        }
        let (symbol, color) = Self.glyph(r)
        image(i, Self.tinted(symbol, color))
        i.state = r.current ? .on : .off
        i.toolTip = [r.detail, r.command].compactMap { $0 }.joined(separator: "\n")
        let port = r.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let hidden = r.session.map(isHidden) == true ? [String(localized: "hidden")] : []
        let place = [Self.source(r)] + (r.running ? [port ?? String(localized: "Running")] : []) + hidden
        let note = r.missing.map { String(localized: "\($0) isn't installed") } ?? place.joined(separator: " · ")
        i.attributedTitle = Self.title(r.name, note: note, column: column, dim: r.missing != nil)
    }

    /// A name, and in grey at `column` what tells it apart.
    static func title(_ name: String, note: String, column: CGFloat, dim: Bool = false) -> NSAttributedString {
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        let t = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab,
                                                                     .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor])
        t.append(NSAttributedString(string: "\t" + note, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab,
                                                                       .foregroundColor: NSColor.secondaryLabelColor]))
        return t
    }

    /// The longest name's width and a gap: where the grey notes start.
    static func column(_ names: [String]) -> CGFloat {
        (names.map { ($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width }.max() ?? 0) + Metrics.inset
    }

    /// What a command is for, the Run menu's sections.
    enum Purpose: CaseIterable {
        case install, run, test, build, deploy, other
        var title: String {
            switch self {
            case .install: String(localized: "Dependencies")
            case .run: String(localized: "Run")
            case .test: String(localized: "Tests")
            case .build: String(localized: "Build & Check")
            case .deploy: String(localized: "Deploy")
            case .other: String(localized: "Other")
            }
        }
    }

    /// By run.detect's kind, and by name for what kinds don't say (deploy, release, rollback; smoke and e2e tests).
    static func purpose(_ r: Row) -> Purpose {
        let n = r.name.lowercased()
        if r.install || ["install", "setup", "bootstrap", "deps"].contains(where: n.hasPrefix) { return .install }
        if ["deploy", "release", "publish", "ship", "rollback"].contains(where: n.hasPrefix) { return .deploy }
        switch r.kind {
        case "run": return r.file == "Dockerfile" ? .other : .run   // building an image to run it: not the everyday server
        case "test": return .test
        case "build", "lint": return .build
        default: return ["smoke", "e2e"].contains(where: n.hasPrefix) ? .test : .other
        }
    }

    /// Its purpose's symbol and colour (green ▶ run, purple flask tests, orange hammer build, blue check lint, red plane
    /// deploy, teal install); the rest in grey, by name. ▶ in a green circle: it runs now.
    static func glyph(_ r: Row) -> (String, NSColor) {
        let n = r.name.lowercased()
        if r.running { return ("play.circle.fill", .systemGreen) }
        switch purpose(r) {
        case .install: return ("arrow.down.circle.fill", .systemTeal)
        case .run: return ("play.fill", .systemGreen)
        case .test: return ("flask.fill", .systemPurple)
        case .build: return r.kind == "lint" ? ("checkmark.circle.fill", .systemBlue) : ("hammer.fill", .systemOrange)
        case .deploy: return (n.hasPrefix("rollback") ? "arrow.uturn.backward.circle.fill" : "paperplane.fill", .systemRed)
        case .other:
            if r.file.contains("compose") || r.file == "Dockerfile" { return ("shippingbox", .secondaryLabelColor) }
            let named: [(words: [String], symbol: String)] = [(["clean"], "trash"), (["migrate", "seed", "db", "backup"], "cylinder"),
                                                              (["log"], "text.alignleft"), (["doc"], "book")]
            return (named.first { $0.words.contains(where: n.hasPrefix) }?.symbol ?? "terminal", .secondaryLabelColor)
        }
    }

    /// A symbol in colour (a menu draws a template image in its text colour); a circled one white on a disc of it — one
    /// colour would paint its mark into the disc.
    static func tinted(_ name: String, _ color: NSColor) -> NSImage? {
        let colors = name.hasSuffix(".circle.fill") ? [.white, color] : [color]
        let look = NSImage.SymbolConfiguration(pointSize: 13, weight: Metrics.iconWeight).applying(.init(paletteColors: colors))
        let i = NSImage.symbol(name, "").withSymbolConfiguration(look)
        i?.isTemplate = false
        return i
    }

    /// Where a command comes from, in a word: its program ("make", "npm", "uv", "compose", ".kelp.yaml") and its folder.
    static func source(_ r: Row) -> String {
        let words = r.command.split(separator: " ").map(String.init)
        var tool = r.file == ".kelp.yaml" ? ".kelp.yaml" : words.first ?? ""
        if tool == "docker", words.dropFirst().first == "compose" { tool = "compose" }
        if tool.hasPrefix(".venv/") { tool = "venv" }
        if tool.hasPrefix("./") { tool = String(tool.dropFirst(2)) }
        return r.folder.isEmpty ? tool : "\(tool) · \((r.folder as NSString).lastPathComponent)"
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

    /// An item's image, kept on macOS 27, whose menus hide the images an item doesn't ask to show.
    private func image(_ i: NSMenuItem, _ image: NSImage?) {
        i.image = image
        #if compiler(>=6.4)   // the macOS 27 SDK
        if #available(macOS 27, *) { i.preferredImageVisibility = .visible }
        #endif
    }

    /// The page a run serves, beside what you're doing.
    func openPage(_ sid: String) {
        guard let r = state.active[sid], let url = r.url else { return }
        app.workbench.open(url, split: .right, workspace: r.workspace, focus: false)
    }

    struct Row {
        var id, name, command: String
        var detail: String?, missing: String?, url: String?
        var running = false, current = false, install = false
        /// Running: its session.
        var session: String?
        /// run.detect's kind (run, test, build, lint, other), the file it comes from, and where it runs ("" the workspace's folder).
        var kind = "other", file = "", folder = ""
    }

    /// Every command the menu offers: .kelp.yaml's, then the files', its own folder's first; what runs, and what ⌘R runs.
    func rows(_ wid: String) -> [Row] {
        let mark = current(wid)?.choice
        let live = Dictionary(running(in: wid).compactMap { sid in app.session(sid).flatMap(choice(of:)).map { ($0, sid) } }) { a, _ in a }
        let kinds = ["run": "run", "test": "test", "build": "build", "lint": "lint"]
        let kelp = (state.kelp[wid] ?? []).map {
            Row(id: "kelp:" + $0.name, name: $0.name, command: $0.command, kind: kinds[$0.name] ?? "other", file: ".kelp.yaml")
        }
        let found = (state.found[wid]?.options ?? []).map { o in
            Row(id: o.id, name: o.kind == "install" ? String(localized: "Install") : o.name, command: o.command, detail: o.detail,
                missing: o.missing, kind: o.kind, file: o.source, folder: o.folder)
        }
        return (kelp + found).map { r in
            var r = r
            r.url = live[r.id].flatMap { state.active[$0]?.url }
            r.running = live[r.id] != nil
            r.session = live[r.id]
            r.current = r.id == mark
            r.install = r.kind == "install"
            return r
        }
    }
}
