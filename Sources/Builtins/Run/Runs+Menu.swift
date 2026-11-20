// The Run menu: its rows by purpose, their symbols, the servers already running, forwarding a port by hand.
import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

extension Runs {
    /// The Run menu. First comes what is already running that the menu didn't start, then the project's commands,
    /// grouped by program ("make", "npm · web") and each named by what it does. Each takes one line: its purpose's
    /// symbol, its name, and the program in grey. When more than three commands say nothing about their purpose, they
    /// go under More, by file. A command's description and its whole command line are its tooltip.
    func menu(_ wid: String) -> NSMenu {
        let runMenu = NSMenu()
        // Servers this menu didn't start (an agent's dev server, one typed in a terminal) come first, so the user sees
        // them before starting a second one.
        let elsewhere = (state.ports[wid] ?? []).filter { port in
            ServedPages.listed(port) && app.session(port.session).map { choice(of: $0) == nil } ?? false
        }
        if !elsewhere.isEmpty {
            runMenu.addItem(.sectionHeader(title: String(localized: "Already Running")))
            for port in elsewhere { server(port, in: runMenu, wid) }
        }
        let rows = rows(wid), rest = rows.filter { $0.purpose == .other }
        let shown = rest.count > 3 ? rows.filter { $0.purpose != .other } : rows
        let tools = shown.map(Self.source).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // The programs' column starts after the longest name.
        let column = NSMenuItem.noteColumn(shown.map(\.name) + [String(localized: "More")])
        for tool in tools {
            if runMenu.numberOfItems > 0 { runMenu.addItem(.separator()) }
            let group = shown.filter { Self.source($0) == tool }.sorted { $0.purpose.rawValue < $1.purpose.rawValue }
            for row in group { item(row, in: runMenu, wid, column: column) }
        }
        if rest.count > 3 {
            let sub = NSMenu(), inSub = NSMenuItem.noteColumn(rest.map(\.name))
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
            more.attributedTitle = NSMenuItem.titleWithNote(
                String(localized: "More"), note: "\(rest.count)", column: column)
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

    /// One command on one line: its purpose's symbol (grey, or green while it runs), its name, and where it comes from
    /// ("make", "npm · web"), with its port while it runs and what's missing when it can't. ⌘R and a check mark go on
    /// what ⌘R runs.
    private func item(_ row: Row, in menu: NSMenu, _ wid: String, column: CGFloat) {
        // While it runs, a click shows its output (its tab may be hidden here) and ⌥ stops it; ⌘R or ▶ starts it over.
        let item = menu.add(row.name, key: row.current ? "r" : "") { [weak self] in
            guard let self else { return }
            if let sid = row.session {
                show(sid)
                return
            }
            Task {
                row.install
                    ? await self.start(
                        wid, row.id, self.app.workbench.sized(RunStart(worktreeId: wid, id: row.id), split: .down))
                    : await self.start(choice: row.id, in: wid)
            }
        }
        defer {
            if let sid = row.session {
                let stop = menu.add(String(localized: "Stop \(row.name)")) { [weak self] in
                    Task { await self?.app.call(SessionKill(id: sid)) }
                }
                // A template, in the text colour: stopping is an action, which has no colour of its own.
                stop.show(NSImage.symbol("stop.fill").withSymbolConfiguration(.chrome()))
                // An alternate pairs with its item by key: ⌥ added to ⌘R, or ⌥ alone.
                stop.keyEquivalent = item.keyEquivalent
                stop.keyEquivalentModifierMask = item.keyEquivalent.isEmpty ? .option : [.command, .option]
                stop.isAlternate = true
            }
        }
        let (symbol, color) = Self.glyph(row)
        item.show(Self.tinted(symbol, row.running ? color : .secondaryLabelColor))
        item.state = row.current ? .on : .off
        item.toolTip = [row.detail, row.command].compactMap { $0 }.joined(separator: "\n")
        // The project's file says what the item runs, so the command shows as a subtitle before it is picked, not only
        // in a tooltip.
        if #available(macOS 14.4, *) { item.subtitle = String((row.detail ?? row.command).prefix(80)) }
        let port = row.url.flatMap { URLComponents(string: $0)?.port }.map { ":\($0)" }
        let hidden = row.session.map(app.workbench.isHidden) == true ? [String(localized: "hidden")] : []
        let place = [Self.source(row)] + (row.running ? [port ?? String(localized: "Running")] : []) + hidden
        let note = row.missing.map { String(localized: "\($0) isn’t installed") } ?? place.joined(separator: " · ")
        item.attributedTitle = NSMenuItem.titleWithNote(row.name, note: note, column: column, dim: row.missing != nil)
    }

    /// What a command is for, which sets the order of a program's commands in the Run menu and their symbol.
    enum Purpose: Int {
        case install, run, test, build, deploy, other
    }

    /// Finds the purpose by run.detect's kind, and by name for what kinds don't say (deploy, release, rollback; smoke
    /// and e2e tests).
    static func purpose(_ row: Row) -> Purpose {
        let name = row.name.lowercased()
        if row.install || ["install", "setup", "bootstrap", "deps"].contains(where: name.hasPrefix) { return .install }
        if ["deploy", "release", "publish", "ship", "rollback"].contains(where: name.hasPrefix) { return .deploy }
        switch row.kind {
        // A Dockerfile's run builds an image to run it, which is not the everyday server.
        case "run": return row.file == "Dockerfile" ? .other : .run
        case "test": return .test
        case "build", "lint": return .build
        default: return ["smoke", "e2e"].contains(where: name.hasPrefix) ? .test : .other
        }
    }

    /// The symbol and colour of a command's purpose: green ▶ run, purple flask tests, orange hammer build, blue
    /// checklist lint, red plane deploy, teal tray install. A thing or an action is drawn in outline, as commit types
    /// are (decision 93), with no circle round it (a circle is a state's mark: the agent's done, an update); ▶ is
    /// filled, as a start is. The Run menu shows the colour only on what runs, so colour says it runs now and
    /// the symbol what for; a run's tab shows the symbol in grey. The rest are grey, chosen by name.
    static func glyph(_ row: Row) -> (String, NSColor) {
        let name = row.name.lowercased()
        switch row.purpose {
        case .install: return ("square.and.arrow.down", .systemTeal)
        case .run: return ("play.fill", .systemGreen)
        case .test: return ("flask", .systemPurple)
        case .build: return row.kind == "lint" ? ("checklist", .systemBlue) : ("hammer", .systemOrange)
        case .deploy:
            return (name.hasPrefix("rollback") ? "arrow.uturn.backward" : "paperplane", .systemRed)
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

    /// A symbol in colour, because a menu draws a template image in its text colour. A circled symbol is white on a
    /// disc of the colour, because one colour would paint its mark into the disc.
    static func tinted(_ name: String, _ color: NSColor) -> NSImage? {
        let key = "\(name)\u{0}\(color)" as NSString   // the same image each time, as NSImage.symbol does
        if let known = symbols.object(forKey: key) { return known }
        let colors = name.hasSuffix(".circle.fill") ? [.white, color] : [color]
        let look = NSImage.SymbolConfiguration.chrome().applying(.init(paletteColors: colors))
        let image = NSImage.symbol(name, "").withSymbolConfiguration(look)
        image?.isTemplate = false
        if let image { symbols.setObject(image, forKey: key) }
        return image
    }
    private static let symbols = NSCache<NSString, NSImage>()

    /// Where a command comes from, in a word: its program ("make", "npm", "uv", "compose", ".kelp.yaml") and its
    /// folder.
    static func source(_ row: Row) -> String {
        let words = row.command.split(separator: " ").map(String.init)
        var tool = row.id.hasPrefix("kelp:") ? row.file : words.first ?? ""
        if tool == "docker", words.dropFirst().first == "compose" { tool = "compose" }
        if tool.hasPrefix(".venv/") { tool = "venv" }
        if tool.hasPrefix("./") { tool = String(tool.dropFirst(2)) }
        return row.folder.isEmpty ? tool : "\(tool) · \((row.folder as NSString).lastPathComponent)"
    }

    /// A server an agent or a terminal started here: what it is (the command the files name, when the agent's
    /// background task runs it, else the program), who started it, and its port. A click opens its page, and ⌥-click
    /// stops it.
    private func server(_ port: PortsList.Port, in menu: NSMenu, _ wid: String) {
        let session = app.session(port.session)
        let agent = session?.agent.flatMap { id in
            !Session.isAgent(id) ? nil : app.catalog.all.first { $0.id == id }
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
            guard let app = self?.app else { return }
            Task { await PageActions(app).stop(pid: port.pid, in: wid) }
        }
        stop.show(.symbol("stop.fill"))
        stop.isAlternate = true
        stop.keyEquivalentModifierMask = .option
    }

    /// Forwards a port Kelp didn't find, on the host or on what the host reaches. It stays until it's turned off.
    private func forwardByHand(_ host: String, _ wid: String) {
        Task {
            let info = String(localized: "A port on the host, or an address it can reach: 5432, db.internal:5432.")
            guard let text = await prompt(String(localized: "Forward a Port from \(host)"), info), !text.isEmpty else {
                return
            }
            if await app.call(PortsForward(worktreeId: wid, target: text)) != nil { app.watchAgain(.ports, wid) }
        }
    }
}
