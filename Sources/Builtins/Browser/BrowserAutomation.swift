import AppKit
import Core
import DesignKit
import WebKit
import WorkbenchKit

/// Carries out `kelp browser`, the commands an agent runs on the page. Kelp's scripts run in a content world of their
/// own (`world`), so the page can't see or change them, but they see its DOM. Clicks and typing are DOM events
/// (`isTrusted` is false), so they work while the tab isn't on screen.
/// Limit: a page that only listens to trusted events ignores them; send AppKit events when one matters.
extension BrowserTab {
    static let world = WKContentWorld.world(name: "kelp.browser")

    func browse(_ action: BrowserAction, _ args: JSONValue) async throws -> JSONValue {
        let name = action.rawValue
        // A subagent's command goes to the subagent's own page in this tab (BrowserPages.swift).
        if agent, host == nil, let page = try pageSet.route(action, args) { return try await page.browse(action, args) }
        if action != .open, awaitsHostNetwork { throw BrowserRequests.noPage }
        defer { (host ?? self).pageSetActed() }
        func need(_ key: String) throws -> String {
            guard let value = args[key]?.string, !value.isEmpty else {
                throw RPCError.invalidParams("\(name) needs \(key)")
            }
            return value
        }
        // The user's logged-in tab belongs to the agent on the one site the user allowed. Once the tab has gone to
        // another site (the user took it there after the agent left it), it belongs to the user again.
        if !agent, let now = web.url, now.scheme != "about", PageOrigin.of(now) != PageOrigin.of(URL(string: start)) {
            throw RPCError.invalidParams(
                "This tab is on another site than the one the user let you use: kelp browser open <url> --shared asks again."
            )
        }
        let drive = watch()
        sized()
        drive.drivenAt = Date()
        // While the user has the page taken over, they may be signing in, so what the page holds now (fields, pixels,
        // requests) is theirs. The command waits for the user to hand the page back, for as long as the daemon waits
        // for its answer. A command that acts on the page still doesn't act then, because the page settling afterwards
        // could outlast the daemon's wait, and the agent, told the command didn't answer, would run it twice.
        if drive.takenOver, !Self.whileTakenOver.contains(action) {
            guard await drive.handedBack(within: Self.handBackWait) else {
                throw RPCError.internalError(
                    "The user has this page still (they took it over): kelp browser info or wait until they hand it "
                        + "back, or kelp browser ask them")
            }
            if !Self.looks.contains(action) {
                throw RPCError.internalError(
                    "The user just handed the page back: nothing was done. kelp browser snapshot to see it now, "
                        + "then run the command again")
            }
        }
        told(action, args)
        return try await looked(action, ref: args["ref"]?.string, try await perform(action, args, drive, need))
    }

    private func perform(
        _ action: BrowserAction, _ args: JSONValue, _ drive: AgentDrive, _ need: (String) throws -> String
    ) async throws -> JSONValue {
        switch action {
        case .console, .network: return .string(listed(action == .console, clear: args["clear"]?.bool == true))
        case .info: return try await settled()
        case .open:
            // When the tab already shows this page, the agent is opening it again after changing the code, so the page
            // reloads with nothing from the cache. A dev server that doesn't ask for revalidation would hand back the
            // old script.
            let url = try need("url")
            let remote = args["remote"] ?? .null
            if requiresHostNetwork || remote != .null { try await onHost(remote) }
            if let now = web.url?.absoluteString, Self.same(now, url) { web.reloadFromOrigin() } else { load(url) }
            return try await settled()
        case .reload:
            reloadPage(fromOrigin: true)
            return try await settled()
        case .viewport: return try await resize(try need("size"))
        case .snapshot:
            let find = args["find"]?.string ?? ""
            let text = try await snapshot(args["ref"]?.string ?? "", max: find.isEmpty ? 1500 : 20000)
            return .string(find.isEmpty ? text : Self.found(find, in: text))
        case .dialog:
            let accept = try need("answer") == "accept", text = accept ? args["text"]?.string : nil
            drive.dialogAnswer = (accept, text)
            guard accept else { return .string("The page's next question gets Cancel") }
            return .string("The page's next question gets OK" + (text.map { " and \"\($0)\"" } ?? ""))
        case .upload, .click, .hover, .drag, .type: return try await onElement(action, try need("ref"), args)
        case .press:
            let before = await probe()
            _ = try await run(Self.pressJS, ["key": try need("key"), "ref": args["ref"]?.string ?? ""])
            return try await settled(after: before)
        case .scroll:
            let before = await probe()
            let at = try await run(Self.scrollJS, ["to": args["to"]?.string ?? "down"]) as? String ?? ""
            return try await settled(["scroll": .string(at)], after: before)
        case .back:
            guard web.canGoBack else { throw RPCError.invalidParams("No page to go back to.") }
            web.goBack()
            return try await settled()
        case .eval:
            // This runs in the page's own world, because the agent asks about the page's state (its globals, its
            // framework). A promise that never settles is cut off here, before the daemon stops waiting, so nothing is
            // left awaiting it.
            let limit = Int(UIBrowser.wait - 10) * 1000
            let body =
                "const v = await Promise.race([(\n\(try need("js"))\n), new Promise((_, no) => setTimeout(() => "
                + "no(new Error('No answer from the script in \(limit / 1000) s')), \(limit)))]);\n"
                + "return v === undefined ? 'null' : (JSON.stringify(v) ?? 'null');"
            let text = try await run(body, page: true) as? String ?? "null"
            let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
            // The CLI prints nothing for null, so the agent couldn't tell the script ran.
            return value == .null ? .string("null") : value
        case .screenshot:
            _ = try await run(Self.calmJS)   // waits until what an earlier action started has played out and been drawn
            let image: NSImage
            do { image = try await web.takeSnapshot(configuration: nil) } catch {
                throw RPCError.internalError(
                    "No screenshot: \(error.localizedDescription) Show the page's tab and try again.")
            }
            guard let path = await Self.savePNG(image, kind: "page", to: args["path"]?.string) else {
                throw RPCError.internalError("Couldn't write the screenshot")
            }
            return .object(["path": .string(path)])
        case .record: return try await record(args)
        case .ask: return try await ask(args)
        case .wait:
            let text = args["text"]?.string, selector = args["selector"]?.string
            let seconds = min(args["timeout"]?.number ?? 10, UIBrowser.wait - 5),
                end = Date().addingTimeInterval(seconds)
            while try await run(Self.waitJS, ["text": text ?? "", "selector": selector ?? ""]) as? Bool != true {
                guard Date() < end else {
                    throw RPCError.internalError("Not on the page after \(Int(seconds)) s: \(text ?? selector ?? "")")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            // Settling gets only what's left of the daemon's wait, because an answer after it would find nobody
            // waiting.
            return try await settled(within: min(30, max(1, UIBrowser.wait - 5 - seconds + end.timeIntervalSinceNow)))
        }
    }

    /// Does an action on the element `ref`. The answer says what the action did (`settled(after:)`).
    private func onElement(_ action: BrowserAction, _ ref: String, _ args: JSONValue) async throws -> JSONValue {
        let reach = Self.findJS + Self.reachJS + Self.flashJS, before = await probe()
        let look = pointerLook(action, ref: ref, args)
        switch action {
        case .upload:
            // The CLI read these files, so they are the agent's files as the agent sees them. The app touches no
            // project file itself.
            let files = (args["files"]?.array ?? []).compactMap { file -> [String: String]? in
                if case .object(let fields) = file { return fields.compactMapValues(\.string) } else { return nil }
            }
            guard !files.isEmpty else { throw RPCError.invalidParams("upload needs a file") }
            let how = try await run(
                Self.findJS + Self.flashJS + Self.uploadJS, shown(["ref": ref, "files": files], look))
            return try await settled(
                how as? String == "dropped" ? ["upload": .string("dropped on \(ref)")] : [:], after: before)
        case .drag:
            guard let onto = args["onto"]?.string, !onto.isEmpty else {
                throw RPCError.invalidParams("drag needs onto")
            }
            _ = try await run(reach + Self.dragJS, shown(["ref": ref, "onto": onto, "editable": false], look))
        case .type:
            let text = args["text"]?.string ?? "", submit = args["submit"]?.bool == true
            let shows = try await run(
                reach + Self.typeJS, shown(["ref": ref, "text": text, "submit": submit, "editable": true], look))
            // `shows` is what the page made of the text (a mask, a length limit, the option picked), when that isn't
            // what was typed.
            let field: [String: JSONValue] = (shows as? String).map { $0 == text ? [:] : ["shows": .string($0)] } ?? [:]
            return try await settled(field, after: before, typing: true)
        default:
            let js = action == .click ? Self.clickJS : Self.hoverJS
            _ = try await run(reach + js, shown(["ref": ref, "editable": false], look))
        }
        return try await settled(after: before)
    }

    /// A page that no pane shows (a tab behind another, a workspace not on screen) has no size, and a page without a
    /// size lays nothing out, so there is no text to read and nothing to click. Such a page gets the agent's viewport,
    /// or else a laptop window's size, until a pane shows it.
    private func sized() {
        guard web.window == nil else { return }
        if let viewport = viewport {
            web.frame = CGRect(origin: .zero, size: viewport)
            return
        }
        guard web.frame.width < 200 || web.frame.height < 200 else { return }
        web.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// Handles `viewport 390x844`, which shows the page at that size (`reset` goes back to the pane's size). It answers
    /// with the size the page now reports.
    private func resize(_ size: String) async throws -> JSONValue {
        if size == "reset" {
            viewport = nil
            if web.window == nil { web.frame = .zero }
        } else {
            let wh = size.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Int($0) }
            guard wh.count == 2, (200...4000).contains(wh[0]), (200...4000).contains(wh[1]) else {
                throw RPCError.invalidParams("viewport takes WIDTHxHEIGHT, 200 to 4000 each (390x844), or reset")
            }
            viewport = CGSize(width: wh[0], height: wh[1])
        }
        placeWeb()
        if web.window == nil { sized() } else { view.layoutSubtreeIfNeeded() }   // off screen, layout would size it to nothing
        // The page takes its new size a moment later, or longer on a busy Mac, so wait until the page reports it (2 s
        // at most). The wait uses a timer, not an animation frame, because a page off screen draws no frames.
        let size = web.window == nil ? web.frame.size : web.bounds.size
        let now = try await run(
            """
            const end = Date.now() + 2000
            while ((innerWidth != w || innerHeight != h) && Date.now() < end) await new Promise(r => setTimeout(r, 50))
            return innerWidth + 'x' + innerHeight
            """, ["w": Int(size.width / web.pageZoom), "h": Int(size.height / web.pageZoom)])
        return try await settled(["viewport": .string(now as? String ?? "")])
    }

    /// How long a command waits for the user to hand the page back: as long as the daemon waits for its answer.
    static var handBackWait = UIBrowser.wait - 10

    /// The actions that only read the page. They still run once the page is handed back, because they change nothing.
    static let looks: Set<BrowserAction> = [.snapshot, .screenshot, .console, .network, .info, .wait]

    /// The actions an agent may still run on a page the user took over. None of them acts on the page.
    static let whileTakenOver: Set<BrowserAction> = [.wait, .info, .record, .ask]   // a recording pauses meanwhile

    /// Returns the snapshot lines that mention `text`, in any case. Each match is shown under the lines that contain
    /// it, so its ref keeps its place, and over up to 20 lines of what is inside it (a heading's list, a form's
    /// fields).
    nonisolated static func found(_ text: String, in snapshot: String) -> String {
        let lines = snapshot.components(separatedBy: "\n")
        guard let head = lines.first else { return "" }
        var keep = kept(lines) { $0.localizedCaseInsensitiveContains(text) }
        let indent = { (line: String) in line.prefix { $0 == " " }.count }
        for match in keep where lines[match].localizedCaseInsensitiveContains(text) {
            let inside = lines[(match + 1)...].prefix { indent($0) > indent(lines[match]) }.prefix(20)
            keep.insert(integersIn: (match + 1)..<(match + 1 + inside.count))
        }
        return keep.isEmpty
            ? head + "\nNothing on the page mentions \"\(text)\"."
            : ([head] + keep.map { lines[$0] }).joined(separator: "\n")
    }

    /// Returns the indexes of the lines that match, skipping the first line (the page's own), and of the lines that
    /// contain each match.
    nonisolated static func kept(_ lines: [String], matching: (String) -> Bool) -> IndexSet {
        var keep = IndexSet()
        for (index, line) in lines.enumerated().dropFirst() where matching(line) {
            keep.insert(index)
            var depth = line.prefix { $0 == " " }.count
            for above in stride(from: index - 1, to: 0, by: -1) where depth > 0 {
                let indent = lines[above].prefix { $0 == " " }.count
                if indent < depth {
                    keep.insert(above)
                    depth = indent
                }
            }
        }
        return keep
    }

    /// Whether two strings spell one address, such as `http://localhost:3000` and `http://localhost:3000/`.
    static func same(_ first: String, _ second: String) -> Bool {
        func bare(_ address: String) -> String { address.hasSuffix("/") ? String(address.dropLast()) : address }
        return bare(first) == bare(second)
    }

    /// Answers with where the page is once what an action started has loaded (a click that navigates), and with the
    /// reason when a load fails. After an action, `before` is the page as it was, and once the page is quiet, `change`
    /// says what the action did: `new page`, `page changed` or `nothing changed`. Typing always changes the field, so
    /// after typing only a change the page made counts.
    func settled(
        _ extra: [String: JSONValue] = [:], within: TimeInterval = 30, after before: Probe? = nil, typing: Bool = false
    ) async throws -> JSONValue {
        let acted = Date()
        try await Task.sleep(for: .milliseconds(150))   // so a navigation the action started has begun
        let end = Date().addingTimeInterval(within)
        // A download the action started is waited for too, so its answer says where the file is.
        while web.isLoading || !downloading.isEmpty || downloadComing, Date() < end {
            try await Task.sleep(for: .milliseconds(100))
        }
        var answer = extra
        if let before {
            let change = Self.change(from: before, to: try await quiet(since: acted))
            if !(typing && change == "nothing changed") { answer["change"] = .string(change) }
        }
        answer.merge(["url": .string(web.url?.absoluteString ?? ""), "title": .string(web.title ?? "")]) { $1 }
        if web.isLoading { answer["loading"] = .bool(true) }
        if let drive, !drive.dialogs.isEmpty {
            answer["dialogs"] = .array(drive.dialogs.map(JSONValue.string))
            drive.dialogs = []
        }
        if let drive, !drive.downloads.isEmpty {
            answer["downloads"] = .array(drive.downloads.map(JSONValue.string))
            drive.downloads = []
        }
        if let loadError { answer["error"] = .string(loadError) }
        return .object(answer)
    }

    /// The state of the page at one moment: which document it is, how many changes it has had, how long since the last
    /// change (ms), and whether it's still parsing. `probe()` returns nil while the page can't say, between two
    /// documents.
    struct Probe: Equatable {
        var doc: Double, url: String, changes: Int, idle: Double, loading: Bool
    }

    func probe() async -> Probe? {
        do {
            guard let probe = try await run(Self.probeJS) as? [String: Any], let doc = probe["doc"] as? Double else {
                return nil
            }
            return Probe(
                doc: doc, url: probe["url"] as? String ?? "", changes: probe["n"] as? Int ?? 0,
                idle: probe["idle"] as? Double ?? 0,
                loading: probe["ready"] as? String == "loading")
        } catch {
            return nil   // a navigation is going on, and the next document answers
        }
    }

    /// Waits until the page is quiet after an action (`acted`) and returns its state. Quiet means parsed, no change to
    /// its DOM for 80 ms, and no request started in the last 1.5 s still out (older ones are long polls and analytics).
    /// The wait lasts at most 0.8 s, or 3 s while a document loads, so a page that never stops (a clock, a ticker)
    /// answers.
    private func quiet(since acted: Date) async throws -> Probe? {
        let start = Date()
        var limit: TimeInterval = 0.8
        while true {
            let now = await probe()
            let loading = web.isLoading || now?.loading != false
            if loading { limit = 3 }
            if let now, !loading, min(now.idle, Date().timeIntervalSince(acted) * 1000) >= 80, drive?.busy != true {
                return now
            }
            if Date().timeIntervalSince(start) >= limit { return now }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    nonisolated static func change(from before: Probe, to after: Probe?) -> String {
        guard let after, after.doc == before.doc, after.url == before.url else { return "new page" }
        return after.changes == before.changes ? "nothing changed" : "page changed"
    }

    /// Returns the arguments of an action the user watches being done. `look` sets the element's glow and the pointer
    /// (the agent's colour and label, from `pointerLook`), and `motion` gives Kelp's timings in ms. The wait before the
    /// action, the typing pace and how long the pointer stays aren't motion, so Reduce Motion keeps them.
    private func shown(_ args: [String: Any], _ look: [String: Any]) -> [String: Any] {
        let ms = { (seconds: TimeInterval) in Int(seconds * 1000) }
        let motion = [
            "appear": ms(Motion.duration(Motion.appear)), "disappear": ms(Motion.duration(Motion.disappear)),
            "flash": ms(Motion.flash), "lead": ms(Motion.appear + Motion.fast), "idle": ms(Motion.wait),
            "key": ms(Motion.stagger), "typing": ms(Motion.linger)
        ]
        return args.merging(look) { $1 }.merging(["motion": motion]) { $1 }
    }

    /// Runs an async function body with `args` as its variables. When the script throws, the error carries the
    /// exception's message.
    func run(_ body: String, _ args: [String: Any] = [:], page: Bool = false) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(
                body, arguments: args, in: nil, contentWorld: page ? .page : Self.world)
        } catch let error as NSError where error.userInfo["WKJavaScriptExceptionMessage"] != nil {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            throw RPCError.internalError(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
        }
    }

}
