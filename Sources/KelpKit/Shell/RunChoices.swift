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
    /// Workspace → its .kelp.yaml's commands, and the file they come from when it's another tool's (`.conductor/settings.toml`).
    var kelp: [String: [ScriptsList.Script]] = [:]
    var kelpFile: [String: String] = [:]
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

    /// What ran last in the workspace's project (its workspaces share it).
    func remembered(_ wid: String) -> String? { project(wid).flatMap { app.uiState["run.last.\($0)"]?.string } }
    func remember(_ choice: String, in wid: String) {
        project(wid).map { app.uiState["run.last.\($0)"] = .string(choice) }
    }

    // MARK: hidden runs

    /// Runs whose tab was put away in the Run menu: they keep running, the menu shows them (`run.hidden` in UIState, so a
    /// restarted Kelp doesn't bring their tabs back).
    /// The sessions the sidebar lists: a run hidden in the Run menu is there, not in the sidebar.
    var shown: [Session] {
        let hidden = state.hidden.union(app.uiState.strings("run.hidden")),
            inTab = Set(app.uiState.strings(Session.inTabKey))
        return app.sessions.filter { !hidden.contains($0.id) && !isOnLine($0, inTab: inTab) }
    }
    func isHidden(_ sid: String) -> Bool {
        state.hidden.contains(sid) || app.uiState.strings("run.hidden").contains(sid)
            || app.session(sid).map { isOnLine($0) } == true
    }
    /// A command its agent's line shows, not moved to a tab of its own (`openInTab`).
    func isOnLine(_ session: Session, inTab: Set<String>? = nil) -> Bool {
        app.sessions.owner(of: session) != nil
            && !(inTab ?? Set(app.uiState.strings(Session.inTabKey))).contains(session.id)
    }
    /// A command off its agent's line, as any tab (it stays one; only live ones are kept in the list).
    package func openInTab(_ sid: String) {
        let live = app.uiState.strings(Session.inTabKey).filter {
            app.session($0).map { $0.status != .exited } ?? false
        }
        app.uiState[Session.inTabKey] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        app.workbench.open(TabURI.session(sid), workspace: app.session(sid)?.worktreeId)
    }
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
    func look(_ session: Session) -> (icon: NSImage?, glow: NSColor?)? {
        guard let wid = session.worktreeId, let picked = choice(of: session),
            var row = rows(wid).first(where: { $0.id == picked })
        else {
            return nil
        }
        row.running = false   // its purpose's mark, not the menu's "running" circle
        let (symbol, color) = Self.glyph(row)
        return (Self.tinted(symbol, color), color == .secondaryLabelColor ? nil : color)
    }

    /// What the workspace serves, its main page first: the title bar's capsule, ⇧⌘O and the sidebar's card.
    func pages(_ wid: String) -> [ServedPage] {
        ServedPages.list(
            printed: running(in: wid).compactMap { state.active[$0]?.url },
            ports: app.latest(PortsEvent.self, wid)?.ports ?? [])
    }

    /// The port after a tab's name: what its run printed, else what its session listens on.
    func port(of session: Session) -> Int? {
        state.active[session.id]?.url.flatMap { URLComponents(string: $0)?.port }
            ?? session.worktreeId.flatMap { app.latest(PortsEvent.self, $0)?.ports }?
            .first { $0.session == session.id && ServedPages.listed($0) }.map { $0.here ?? $0.port }
    }

    /// The page as this Mac reaches it, the ports read again when that moved it; nil and a banner when it can't be.
    func reach(_ page: ServedPage, in wid: String) async -> ServedPage? {
        let here = await page.reached(in: wid) { await app.call($0) }
        if here != page { app.watchAgain(.ports, wid) }
        return here
    }

    /// A page beside what you're doing, or the tab that shows it; what isn't one (a database) gets its address copied.
    func open(_ page: ServedPage, in wid: String) {
        Task {
            guard let page = await reach(page, in: wid) else { return }
            guard page.isWeb else {
                copy(page)
                return
            }
            app.workbench.open(page.url, split: .right, workspace: wid, focus: false)
        }
    }

    func copy(_ page: ServedPage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.address, forType: .string)
        Banner.show(String(localized: "Copied \(page.address)"))
    }

    /// A run that couldn't start: who holds its port, when that's one of Kelp's own screens on this Mac.
    func portBusy(_ event: PortBusyEvent) {
        Task {
            for worktree in app.worktrees where !worktree.archived && RemoteHost.of(worktree.path) == nil {
                guard
                    let port = await app.quiet(PortsList(worktreeId: worktree.id))?.first(where: {
                        $0.port == event.port && $0.session != event.session
                    })
                else { continue }
                let screen = app.groupName(worktree) ?? app.projectName(worktree.repoId) ?? worktree.displayName
                Banner.show(
                    String(localized: ":\(event.port) is taken: \(port.command) on \(screen)."),
                    action: (
                        String(localized: "Show"),
                        { [app] in
                            app.workbench.focus(session: port.session)
                        }
                    ))
                return
            }
        }
    }

    /// ⇧⌘O: the main page of the workspace on screen.
    func openPage() {
        guard let wid = app.workbench.workspaceId, let page = pages(wid).first else {
            NSSound.beep()
            return
        }
        open(page, in: wid)
    }
    private func project(_ wid: String) -> String? { app.worktree(wid)?.repoId }

    /// What the workspace's files offer, read again (on a remote host: one ssh call). Quiet: the list says what it has.
    @discardableResult func detect(_ wid: String) async -> RunDetect.Result? {
        guard let result = await app.quiet(RunDetect(worktreeId: wid)) else { return state.found[wid] }
        if state.found[wid] != result { state.found[wid] = result }
        return result
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
            return state.kelp[wid]?.first { "kelp:" + $0.name == choice }.map { Self.short($0.command) }
                ?? String(choice.dropFirst(5))
        }
        guard let option = state.found[wid]?.options.first(where: { $0.id == choice }) else {
            return choice.split(separator: "|").last.map(String.init) ?? choice
        }
        return (option.folder.isEmpty ? "" : "\((option.folder as NSString).lastPathComponent) › ")
            + Self.short(option.command)
    }

    /// A command as one short line (32 characters), whole in tips.
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

    /// What the empty workspace and the "+" menu offer to run, as the chip names it: its label, its command, and whether
    /// it's only a guess (then ⌘R lists the choices instead of running it).
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

    /// The Run menu under the chip, as Xcode's scheme menu: a section per file, what ⌘R runs checked, what runs now said
    /// under its name. Shown with what's known; the files are read again for next time (at once if nothing is known yet).
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
            // 4 pt under the chip, as the title bar's other menus; without the chip (focus mode), near the window's top.
            if let below = button ?? anchor, below.window != nil {
                runMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: below.bounds.height + 4), in: below)
            } else if let content = app.workbench.window?.window?.contentView {
                runMenu.popUp(
                    positioning: nil, at: NSPoint(x: content.bounds.midX - 120, y: content.bounds.maxY - 40),
                    in: content)
            }
        }
    }

    /// The ports the workspace's sessions listen on: a run's page found again (it printed it before Kelp restarted), and
    /// the servers an agent or a terminal started, for the menu's first section.
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

    /// The Run menu: what's already running that it didn't start, then the project's commands a group a program ("make",
    /// "npm · web"), each by what it does, a line each: its purpose's symbol, its name, the program in grey; more than three
    /// that say nothing of their purpose go under More, by file. A description and the whole command are the tip.
    private func menu(_ wid: String) -> NSMenu {
        let runMenu = NSMenu()
        // Servers this menu didn't start (an agent's dev server, one typed in a terminal): before starting a second one.
        let elsewhere = (state.ports[wid] ?? []).filter { port in
            ServedPages.listed(port) && app.session(port.session).map { choice(of: $0) == nil } ?? false
        }
        if !elsewhere.isEmpty {
            runMenu.addItem(.sectionHeader(title: String(localized: "Already Running")))
            for port in elsewhere { server(port, in: runMenu, wid) }
        }
        let rows = rows(wid), rest = rows.filter { Self.purpose($0) == .other }
        let shown = rest.count > 3 ? rows.filter { Self.purpose($0) != .other } : rows
        let tools = shown.map(Self.source).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let column = Self.column(shown.map(\.name) + [String(localized: "More")])   // the programs, after the longest name
        for tool in tools {
            if runMenu.numberOfItems > 0 { runMenu.addItem(.separator()) }
            let group = shown.filter { Self.source($0) == tool }.sorted {
                Self.purpose($0).rawValue < Self.purpose($1).rawValue
            }
            for row in group { item(row, in: runMenu, wid, column: column) }
        }
        if rest.count > 3 {
            let sub = NSMenu(), inSub = Self.column(rest.map(\.name))
            var file = ""
            for row in rest {
                let from = row.folder.isEmpty ? row.file : "\(row.folder) · \(row.file)"
                if from != file {
                    sub.addItem(.sectionHeader(title: from))
                    file = from
                }
                item(row, in: sub, wid, column: inSub)
            }
            let more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            more.attributedTitle = Self.title(String(localized: "More"), note: "\(rest.count)", column: column)
            more.show(.symbol("ellipsis.circle"))
            if runMenu.numberOfItems > 0 { runMenu.addItem(.separator()) }
            runMenu.addItem(more)
            runMenu.setSubmenu(sub, for: more)
        }
        if rows.isEmpty {
            runMenu.addItem(withTitle: String(localized: "Nothing to run found"), action: nil, keyEquivalent: "")
                .isEnabled =
                false
        }
        runMenu.addItem(.separator())
        if let host = app.worktree(wid).flatMap({ RemoteHost.of($0.path)?.host }) {
            runMenu.add(String(localized: "Forward a Port from \(host)…"), symbol: "network") { [weak self] in
                self?.forwardByHand(host, wid)
            }
        }
        runMenu.add(String(localized: "Edit Commands…"), symbol: "pencil") { [weak self] in self?.edit() }
        return runMenu
    }

    /// One command on one line: its purpose's symbol (grey; green while it runs), its name, where it comes from ("make",
    /// "npm · web") — and its port while it runs, what's missing when it can't. ⌘R and a check for what ⌘R runs.
    private func item(_ row: Row, in menu: NSMenu, _ wid: String, column: CGFloat) {
        // Running: a click shows its output (its tab may be hidden here), ⌥ stops it; ⌘R or ▶ starts it over.
        let item = menu.add(row.name, key: row.current ? "r" : "") { [weak self] in
            guard let self else { return }
            if let sid = row.session {
                show(sid)
                return
            }
            Task {
                row.install
                    ? await self.start(wid, row.id, RunStart(worktreeId: wid, id: row.id))
                    : await self.start(choice: row.id, in: wid)
            }
        }
        defer {
            if let sid = row.session {
                let stop = menu.add(String(localized: "Stop \(row.name)")) { [weak self] in
                    Task { await self?.app.call(SessionKill(id: sid)) }
                }
                stop.show(Self.tinted("stop.circle.fill", .systemRed))
                // an alternate pairs with its item by key: ⌥ added to ⌘R, or ⌥ alone
                stop.keyEquivalent = item.keyEquivalent
                stop.keyEquivalentModifierMask = item.keyEquivalent.isEmpty ? .option : [.command, .option]
                stop.isAlternate = true
            }
        }
        let (symbol, color) = Self.glyph(row)
        item.show(Self.tinted(symbol, row.running ? color : .secondaryLabelColor))
        item.state = row.current ? .on : .off
        item.toolTip = [row.detail, row.command].compactMap { $0 }.joined(separator: "\n")
        // What it runs is the project's file's to say: seen before it's picked, not only on a hover.
        if #available(macOS 14.4, *) { item.subtitle = String((row.detail ?? row.command).prefix(80)) }
        let port = row.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let hidden = row.session.map(isHidden) == true ? [String(localized: "hidden")] : []
        let place = [Self.source(row)] + (row.running ? [port ?? String(localized: "Running")] : []) + hidden
        let note = row.missing.map { String(localized: "\($0) isn't installed") } ?? place.joined(separator: " · ")
        item.attributedTitle = Self.title(row.name, note: note, column: column, dim: row.missing != nil)
    }

    /// A name, and in grey at `column` what tells it apart.
    static func title(
        _ name: String, note: String, column: CGFloat, dim: Bool = false, noteColor: NSColor = .secondaryLabelColor
    ) -> NSAttributedString {
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab,
                .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor
            ])
        text.append(
            NSAttributedString(
                string: "\t" + note,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tab, .foregroundColor: noteColor]))
        return text
    }

    /// The longest name's width and a gap: where the grey notes start.
    static func column(_ names: [String]) -> CGFloat {
        (names.map { ($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width }.max() ?? 0)
            + Metrics.inset
    }

    /// What a command is for: the order of a program's commands in the Run menu, its symbol.
    enum Purpose: Int {
        case install, run, test, build, deploy, other
    }

    /// By run.detect's kind, and by name for what kinds don't say (deploy, release, rollback; smoke and e2e tests).
    static func purpose(_ row: Row) -> Purpose {
        let name = row.name.lowercased()
        if row.install || ["install", "setup", "bootstrap", "deps"].contains(where: name.hasPrefix) { return .install }
        if ["deploy", "release", "publish", "ship", "rollback"].contains(where: name.hasPrefix) { return .deploy }
        switch row.kind {
        // building an image to run it: not the everyday server
        case "run": return row.file == "Dockerfile" ? .other : .run
        case "test": return .test
        case "build", "lint": return .build
        default: return ["smoke", "e2e"].contains(where: name.hasPrefix) ? .test : .other
        }
    }

    /// Its purpose's symbol and colour (green ▶ run, purple flask tests, orange hammer build, blue check lint, red plane
    /// deploy, teal install) — the colour for a run's tab; the Run menu shows it only on what runs. The rest in grey, by
    /// name. ▶ in a green circle: it runs now.
    static func glyph(_ row: Row) -> (String, NSColor) {
        let name = row.name.lowercased()
        if row.running { return ("play.circle.fill", .systemGreen) }
        switch purpose(row) {
        case .install: return ("arrow.down.circle.fill", .systemTeal)
        case .run: return ("play.fill", .systemGreen)
        case .test: return ("flask.fill", .systemPurple)
        case .build: return row.kind == "lint" ? ("checkmark.circle.fill", .systemBlue) : ("hammer.fill", .systemOrange)
        case .deploy:
            return (name.hasPrefix("rollback") ? "arrow.uturn.backward.circle.fill" : "paperplane.fill", .systemRed)
        case .other:
            if row.file.contains("compose") || row.file == "Dockerfile" { return ("shippingbox", .secondaryLabelColor) }
            let named: [(words: [String], symbol: String)] = [
                (["clean"], "trash"), (["migrate", "seed", "db", "backup"], "cylinder"),
                (["log"], "text.alignleft"), (["doc"], "book")
            ]
            return (
                named.first { $0.words.contains(where: name.hasPrefix) }?.symbol ?? "terminal", .secondaryLabelColor
            )
        }
    }

    /// A symbol in colour (a menu draws a template image in its text colour); a circled one white on a disc of it — one
    /// colour would paint its mark into the disc.
    static func tinted(_ name: String, _ color: NSColor) -> NSImage? {
        let key = "\(name)\u{0}\(color)" as NSString   // the same image each time, as NSImage.symbol
        if let known = symbolCache.object(forKey: key) { return known }
        let colors = name.hasSuffix(".circle.fill") ? [.white, color] : [color]
        let look = NSImage.SymbolConfiguration.chrome().applying(.init(paletteColors: colors))
        let image = NSImage.symbol(name, "").withSymbolConfiguration(look)
        image?.isTemplate = false
        if let image { symbolCache.setObject(image, forKey: key) }
        return image
    }

    /// Where a command comes from, in a word: its program ("make", "npm", "uv", "compose", ".kelp.yaml") and its folder.
    static func source(_ row: Row) -> String {
        let words = row.command.split(separator: " ").map(String.init)
        var tool = row.id.hasPrefix("kelp:") ? row.file : words.first ?? ""
        if tool == "docker", words.dropFirst().first == "compose" { tool = "compose" }
        if tool.hasPrefix(".venv/") { tool = "venv" }
        if tool.hasPrefix("./") { tool = String(tool.dropFirst(2)) }
        return row.folder.isEmpty ? tool : "\(tool) · \((row.folder as NSString).lastPathComponent)"
    }

    /// A server an agent or a terminal started here: what it is (the command the files name, when the agent's background
    /// task runs it; else the program), who started it and its port. A click opens its page; with ⌥, it stops.
    private func server(_ port: PortsList.Port, in menu: NSMenu, _ wid: String) {
        let session = app.session(port.session)
        let agent = session?.agent.flatMap { id in
            ["shell", "custom"].contains(id) ? nil : app.catalog.all.first { $0.id == id }
        }
        let tasks = session?.background ?? []
        let what =
            state.found[wid]?.options.first { option in tasks.contains { $0.contains(option.command) } }?.name
            ?? port.command
        let page = ServedPage(port)
        let open = menu.add(what) { [weak self] in self?.open(page, in: wid) }
        open.show(agent.flatMap { app.catalog.icon($0.id) } ?? .symbol("terminal"))
        open.toolTip = String(localized: "Open \(page.url)")
        if #available(macOS 14.4, *) {
            open.subtitle = "\(agent?.name ?? String(localized: "Terminal")) · \(page.place)"
        }
        let stop = menu.add(String(localized: "Stop \(what)")) { [weak self] in
            Task { await self?.app.call(PortsStop(worktreeId: wid, pid: Int(port.pid))) }
        }
        stop.show(.symbol("stop.circle"))
        stop.isAlternate = true
        stop.keyEquivalentModifierMask = .option
    }

    /// A port Kelp didn't find: on the host, or on what the host reaches. Stays until it's turned off.
    private func forwardByHand(_ host: String, _ wid: String) {
        Task {
            let info = String(localized: "A port on the host, or an address it can reach: 5432, db.internal:5432.")
            guard let text = await prompt(String(localized: "Forward a Port from \(host)"), info), !text.isEmpty else {
                return
            }
            if await app.call(PortsForward(worktreeId: wid, target: text)) != nil { app.watchAgain(.ports, wid) }
        }
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
            return row
        }
    }
}
