import AppKit
import Core
import DesignKit
import WebKit
import WorkbenchKit

/// `kelp browser`: what an agent does on the page. Kelp's scripts run in a world of their own (`world`): the page can't see
/// or change them, but they see its DOM. Clicks and typing are DOM events (`isTrusted` false), so they work while the tab
/// isn't on screen. Limit: a page that only listens to trusted events ignores them; send AppKit events when one matters.
extension BrowserTab {
    static let world = WKContentWorld.world(name: "kelp.browser")

    func browse(_ name: String, _ args: JSONValue) async throws -> JSONValue {
        guard let action = BrowserAction(rawValue: name) else {
            throw RPCError.invalidParams("kelp browser knows no \(name)")
        }
        func need(_ key: String) throws -> String {
            guard let value = args[key]?.string, !value.isEmpty else {
                throw RPCError.invalidParams("\(name) needs \(key)")
            }
            return value
        }
        // The user's logged-in tab is the agent's on the one site the user allowed: taken elsewhere since (by the user, once
        // the agent left it), it's theirs.
        if !agent, let now = web.url, now.scheme != "about", PageOrigin.of(now) != PageOrigin.of(URL(string: start)) {
            throw RPCError.invalidParams(
                "This tab is on another site than the one the user let you use: kelp browser open <url> --shared asks again."
            )
        }
        let drive = watch()
        sized()
        drive.drivenAt = Date()
        // Taken over, the user may be signing in: what the page holds now (fields, pixels, requests) is theirs.
        if drive.takenOver, !Self.whileTakenOver.contains(action) {
            throw RPCError.internalError("The user took this page over: only wait and info until they hand it back")
        }
        switch action {
        case .console, .network: return .string(listed(action == .console, clear: args["clear"]?.bool == true))
        case .info: return try await settled()
        case .open:
            // The page it shows already: an agent opens it again after changing the code, so nothing comes from the cache
            // (a dev server that doesn't ask for revalidation would hand back the old script).
            let url = try need("url")
            if let now = web.url?.absoluteString, Self.same(now, url) { web.reloadFromOrigin() } else { load(url) }
            return try await settled()
        case .reload:
            web.reloadFromOrigin()
            return try await settled()
        case .viewport: return try await resize(try need("size"))
        case .snapshot:
            let find = args["find"]?.string ?? ""
            let text =
                try await run(Self.snapshotJS, ["ref": args["ref"]?.string ?? "", "max": find.isEmpty ? 1500 : 20000])
                as? String ?? ""
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
            // The page's own world: the agent asks about the page's state (its globals, its framework).
            // A promise that never settles ends here, before the daemon stops waiting: nothing is left awaiting it.
            let limit = Int(UIBrowser.wait - 10) * 1000
            let body =
                "const v = await Promise.race([(\n\(try need("js"))\n), new Promise((_, no) => setTimeout(() => "
                + "no(new Error('No answer from the script in \(limit / 1000) s')), \(limit)))]);\n"
                + "return v === undefined ? 'null' : (JSON.stringify(v) ?? 'null');"
            let text = try await run(body, page: true) as? String ?? "null"
            let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
            // The CLI prints nothing for null: the agent couldn't tell it ran.
            return value == .null ? .string("null") : value
        case .screenshot:
            _ = try await run(Self.calmJS)   // what an action started has played out and been drawn
            let image: NSImage
            do { image = try await web.takeSnapshot(configuration: nil) } catch {
                throw RPCError.internalError(
                    "No screenshot: \(error.localizedDescription) Show the page's tab and try again.")
            }
            guard let path = Self.savePNG(image, kind: "page", to: args["path"]?.string) else {
                throw RPCError.internalError("Couldn't write the screenshot")
            }
            return .object(["path": .string(path)])
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
            // What's left of the daemon's wait: an answer after it would find nobody waiting.
            return try await settled(within: min(30, max(1, UIBrowser.wait - 5 - seconds + end.timeIntervalSinceNow)))
        }
    }

    /// An action on the element of `ref`: its answer says what it did (`settled(after:)`).
    private func onElement(_ action: BrowserAction, _ ref: String, _ args: JSONValue) async throws -> JSONValue {
        let reach = Self.findJS + Self.reachJS + Self.flashJS, before = await probe()
        switch action {
        case .upload:
            // The CLI read them: the agent's files, as it sees them (the app touches no project file itself).
            let files = (args["files"]?.array ?? []).compactMap { file -> [String: String]? in
                if case .object(let fields) = file { return fields.compactMapValues(\.string) } else { return nil }
            }
            guard !files.isEmpty else { throw RPCError.invalidParams("upload needs a file") }
            let how = try await run(Self.findJS + Self.flashJS + Self.uploadJS, shown(["ref": ref, "files": files]))
            return try await settled(
                how as? String == "dropped" ? ["upload": .string("dropped on \(ref)")] : [:], after: before)
        case .drag:
            guard let onto = args["onto"]?.string, !onto.isEmpty else {
                throw RPCError.invalidParams("drag needs onto")
            }
            _ = try await run(reach + Self.dragJS, shown(["ref": ref, "onto": onto, "editable": false]))
        case .type:
            let text = args["text"]?.string ?? "", submit = args["submit"]?.bool == true
            let shows = try await run(
                reach + Self.typeJS, shown(["ref": ref, "text": text, "submit": submit, "editable": true]))
            // What the page made of it (a mask, a length limit, the option picked), when that isn't what was typed.
            let field: [String: JSONValue] = (shows as? String).map { $0 == text ? [:] : ["shows": .string($0)] } ?? [:]
            return try await settled(field, after: before, typing: true)
        default:
            let js = action == .click ? Self.clickJS : Self.hoverJS
            _ = try await run(reach + js, shown(["ref": ref, "editable": false]))
        }
        return try await settled(after: before)
    }

    /// A page no pane shows (a tab behind another, a workspace not on screen) has no size, and one with none lays nothing
    /// out: no text to read, nothing to click. It gets the agent's viewport, else a laptop window's size, until a pane shows it.
    private func sized() {
        guard web.window == nil else { return }
        if let viewport = drive?.viewport {
            web.frame = CGRect(origin: .zero, size: viewport)
            return
        }
        guard web.frame.width < 200 || web.frame.height < 200 else { return }
        web.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// `viewport 390x844`: the page at that size (`reset`: the pane's), and the size the page now says it has.
    private func resize(_ size: String) async throws -> JSONValue {
        if size == "reset" {
            drive?.viewport = nil
            if web.window == nil { web.frame = .zero }
        } else {
            let wh = size.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Int($0) }
            guard wh.count == 2, (200...4000).contains(wh[0]), (200...4000).contains(wh[1]) else {
                throw RPCError.invalidParams("viewport takes WIDTHxHEIGHT, 200 to 4000 each (390x844), or reset")
            }
            drive?.viewport = CGSize(width: wh[0], height: wh[1])
        }
        placeWeb()
        if web.window == nil { sized() } else { view.layoutSubtreeIfNeeded() }   // off screen, layout would size it to nothing
        // The page takes its new size a moment later, longer on a busy Mac: wait until it says so (2 s at most). A timer,
        // not a frame: a page off screen draws none.
        let size = web.window == nil ? web.frame.size : web.bounds.size
        let now = try await run(
            """
            const end = Date.now() + 2000
            while ((innerWidth != w || innerHeight != h) && Date.now() < end) await new Promise(r => setTimeout(r, 50))
            return innerWidth + 'x' + innerHeight
            """, ["w": Int(size.width / web.pageZoom), "h": Int(size.height / web.pageZoom)])
        return try await settled(["viewport": .string(now as? String ?? "")])
    }

    /// What an agent may still do on a page the user took over: look.
    static let whileTakenOver: Set<BrowserAction> = [.wait, .info]

    /// The snapshot's lines that mention `text` (any case), each under the lines it sits in, so a ref keeps its place.
    nonisolated static func found(_ text: String, in snapshot: String) -> String {
        let lines = snapshot.components(separatedBy: "\n")
        guard let head = lines.first else { return "" }
        var keep = IndexSet()
        for (index, line) in lines.enumerated().dropFirst() where line.localizedCaseInsensitiveContains(text) {
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
        return keep.isEmpty
            ? head + "\nNothing on the page mentions \"\(text)\"."
            : ([head] + keep.map { lines[$0] }).joined(separator: "\n")
    }

    /// Two spellings of one address: `http://localhost:3000` and `http://localhost:3000/`.
    static func same(_ first: String, _ second: String) -> Bool {
        func bare(_ address: String) -> String { address.hasSuffix("/") ? String(address.dropLast()) : address }
        return bare(first) == bare(second)
    }

    /// Where the page is once what an action started has loaded (a click that navigates); a load that fails says why.
    /// After an action (`before`: the page as it was), once the page is quiet, `change` says what the action did: `new
    /// page`, `page changed` or `nothing changed`. Typing changes the field: for it only a change the page made counts.
    private func settled(
        _ extra: [String: JSONValue] = [:], within: TimeInterval = 30, after before: Probe? = nil, typing: Bool = false
    ) async throws -> JSONValue {
        let acted = Date()
        try await Task.sleep(for: .milliseconds(150))   // a navigation the action started has begun
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

    /// The page at a moment: which document, how many changes it has had, how long since the last (ms), and whether it's
    /// still parsing. Nil while it can't say (between two documents).
    struct Probe: Equatable {
        var doc: Double, url: String, changes: Int, idle: Double, loading: Bool
    }

    func probe() async -> Probe? {
        do {
            guard let p = try await run(Self.probeJS) as? [String: Any], let doc = p["doc"] as? Double else {
                return nil
            }
            return Probe(
                doc: doc, url: p["url"] as? String ?? "", changes: p["n"] as? Int ?? 0, idle: p["idle"] as? Double ?? 0,
                loading: p["ready"] as? String == "loading")
        } catch {
            return nil   // a navigation going on: the next document answers
        }
    }

    /// The page once it's quiet after an action (`acted`): parsed, no change to its DOM for 80 ms, and no request it
    /// started in the last 1.5 s still out (older ones are long polls and analytics). At most 0.8 s, 3 s while a
    /// document loads: a page that never stops (a clock, a ticker) answers then.
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

    /// The arguments of an action the user sees done: the element's glow, in the accent colour and Kelp's motion (ms).
    /// The wait before the action, the typing pace and how long the pointer stays aren't motion: Reduce Motion keeps them.
    private func shown(_ args: [String: Any]) -> [String: Any] {
        let ms = { (seconds: TimeInterval) in Int(seconds * 1000) }
        let motion = [
            "appear": ms(Motion.duration(Motion.appear)), "disappear": ms(Motion.duration(Motion.disappear)),
            "flash": ms(Motion.flash), "lead": ms(Motion.appear + Motion.fast), "idle": ms(Motion.wait),
            "key": ms(Motion.stagger), "typing": ms(Motion.linger)
        ]
        return args.merging(["accent": NSColor.themeAccent.hexString, "motion": motion]) { $1 }
    }

    /// An async function body with `args` as its variables; a script's exception comes back as its message.
    private func run(_ body: String, _ args: [String: Any] = [:], page: Bool = false) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(
                body, arguments: args, in: nil, contentWorld: page ? .page : Self.world)
        } catch let error as NSError where error.userInfo["WKJavaScriptExceptionMessage"] != nil {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            throw RPCError.internalError(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
        }
    }

}
