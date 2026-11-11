import Core
import Foundation
import UniformTypeIdentifiers

extension Main {
    static let browserUsage = """
        browser open <url> [--shared] | snapshot [ref] [--find text] | click <ref> | hover <ref> | type <ref> <text> [--submit]
                | drag <ref> <onto-ref|css> | press <key> [ref] | upload <ref> <file>… | dialog accept [text]|dismiss
                | scroll [down|up|top|bottom|<ref>] | back | reload | eval <js>|- | viewport <WxH>|reset
                | screenshot [file] | wait [--text t] [--selector css] [--timeout 10] | console [--clear] | network [--clear] | info
                [--json] · no action: one a line from stdin (kelp browser <<'EOF' … EOF)
        """

    /// `browser <action>`: a page tab in the app, beside the agent's terminal, driven from here (`UIBrowser`). With no
    /// action, the actions come from stdin, one a line, each answered under its own line, until one fails.
    static func browser(_ sub: String?, _ c: RPCClient) async throws {
        var sub = sub
        let json = sub == "--json" || has("--json")
        if sub == "--json" { sub = args.isEmpty ? nil : args.removeFirst() }
        let workspace = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c)?.id
        guard let sub else {
            guard isatty(0) == 0 else { fail("usage: kelp " + browserUsage) }
            while let read = readLine() {
                let line = read.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                print("› " + line)
                fflush(stdout)   // before an error, which goes to stderr unbuffered
                // The rest of an eval's line is its script as written: no quoting to get through.
                if let js = line.firstMatch(of: /^eval\s+(.+)$/)?.1 {
                    args = []
                    try await browse("eval", js: String(js), c, workspace, json: json)
                } else {
                    args = words(line)
                    try await browse(args.removeFirst(), c, workspace, json: json)
                }
            }
            return
        }
        try await browse(sub, c, workspace, json: json)
    }

    /// One action, its answer printed: as lines (`browserText`), or as the JSON it came as.
    static func browse(_ sub: String, js: String? = nil, _ c: RPCClient, _ workspace: String?, json: Bool) async throws
    {
        guard let action = BrowserAction(rawValue: sub) else { fail("usage: kelp " + browserUsage) }
        var params = js.map { ["js": .string($0)] } ?? browserParams(action)
        // Whose pointer the user sees on the page: the agent's name and colour.
        if let session = ProcessInfo.processInfo.environment["KELP_SESSION"] { params["session"] = .string(session) }
        let answer = try await c.call(UIBrowser(action: action.rawValue, args: .object(params), worktreeId: workspace))
        let what = [params["key"]?.string, params["ref"]?.string ?? params["to"]?.string].compactMap { $0 }
        if !json, let text = browserText(action, what.joined(separator: " "), answer) {
            print(text)
        } else {
            show(answer)
        }
        fflush(stdout)
    }

    /// An action's parameters, from the words after it (`args`).
    static func browserParams(_ action: BrowserAction) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        switch action {
        case .open:
            params["shared"] = .bool(has("--shared"))
            guard let url = args.first else { fail("browser open <url> [--shared]") }
            params["url"] = .string(address(url))
        case .click, .hover:
            guard let ref = args.first else { fail("browser \(action) <ref>") }
            params["ref"] = .string(ref)
        case .press:
            guard let key = args.first else {
                fail("browser press <key> [ref]  (Enter, Escape, Tab, Shift+Tab, ArrowDown, a…)")
            }
            params["key"] = .string(key)
            if args.count > 1 { params["ref"] = .string(args[1]) }
        case .drag:
            guard args.count == 2 else { fail("browser drag <ref> <onto-ref | css selector>") }
            params["ref"] = .string(args[0])
            params["onto"] = .string(args[1])
        case .scroll: params["to"] = .string(args.first ?? "down")
        case .type:
            params["submit"] = .bool(has("--submit"))
            guard args.count >= 2 else { fail("browser type <ref> <text> [--submit]") }
            params["ref"] = .string(args[0])
            params["text"] = .string(args.dropFirst().joined(separator: " "))
        case .eval:
            // `eval -`: the script from stdin, as written (a heredoc keeps the shell off its quotes).
            if args == ["-"] {
                params["js"] = .string(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
            } else {
                params["js"] = .string(args.joined(separator: " "))
            }
        case .screenshot:
            if let file = args.first { params["path"] = .string(URL(fileURLWithPath: file).standardizedFileURL.path) }
        case .wait:
            if let text = flag("--text") { params["text"] = .string(text) }
            if let selector = flag("--selector") { params["selector"] = .string(selector) }
            if let timeout = flag("--timeout").flatMap(Double.init) { params["timeout"] = .double(timeout) }
        case .console, .network: params["clear"] = .bool(has("--clear"))
        case .snapshot:
            if let find = flag("--find") { params["find"] = .string(find) }
            if let ref = args.first { params["ref"] = .string(ref) }
        case .upload:
            guard args.count >= 2 else { fail("browser upload <ref> <file>…") }
            params["ref"] = .string(args[0])
            params["files"] = .array(args.dropFirst().map(uploaded))
        case .dialog:
            guard let answer = args.first, ["accept", "dismiss"].contains(answer) else {
                fail("browser dialog accept [text] | dismiss")
            }
            params["answer"] = .string(answer)
            if args.count > 1 { params["text"] = .string(args.dropFirst().joined(separator: " ")) }
        case .viewport:
            guard let size = args.first else {
                fail("browser viewport <width>x<height> | reset  (390x844, 768x1024, 1440x900)")
            }
            params["size"] = .string(size)
        case .info, .back, .reload: break
        }
        if case .eval = action, params["js"]?.string?.isEmpty != false {
            fail("browser eval <js> | eval - (from stdin)")
        }
        return params
    }

    /// An answer as an agent reads it at a glance: what was done to what and what came of it (`click e2 button "Idle" →
    /// nothing changed`), or where the page is; then the page's questions, downloads, and the lines it brought. Nil for
    /// what has no such shape (a snapshot's text, eval's value): printed as it came.
    static func browserText(_ action: BrowserAction, _ what: String, _ answer: JSONValue) -> String? {
        guard action != .eval, case .object(let f) = answer else { return nil }   // eval's value is the page's
        if action == .screenshot { return f["path"]?.string }
        let page = "page \(quoted(f["title"]?.string ?? "")) \(f["url"]?.string ?? "")"
        var lines: [String]
        switch action {
        case .open, .reload, .back, .info, .viewport, .wait:
            let found = action == .wait ? "shown · " : ""
            lines = [found + page + (f["viewport"]?.string.map { " · viewport \($0)" } ?? "")]
        default:
            let came = [
                f["upload"]?.string, f["shows"]?.string.map { "shows " + quoted($0) },
                f["scroll"]?.string.map { "at " + $0 },
                f["change"]?.string.map { $0 == "new page" ? "new " + page : $0 }
            ].compactMap { $0 }
            let head = [action.rawValue, what, f["element"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            lines = [head + " → " + (came.isEmpty ? "done" : came.joined(separator: ", "))]
        }
        if f["loading"]?.bool == true { lines.append("(still loading)") }
        if let error = f["error"]?.string { lines.append("failed: " + error) }
        lines += (f["dialogs"]?.array ?? []).compactMap(\.string).map { "dialog: " + $0 }
        lines += (f["downloads"]?.array ?? []).compactMap(\.string).map { "download: " + $0 }
        if let shown = f["page"]?.string ?? f["new"]?.string, !shown.isEmpty { lines.append(shown) }
        return lines.joined(separator: "\n")
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A line's words as a shell splits them: spaces apart, '…' as it is, "…" with \" and \\ inside, \ before one char.
    static func words(_ line: String) -> [String] {
        var out: [String] = [], word = "", inWord = false, quote: Character?, escaped = false
        for ch in line {
            if escaped {
                word.append(ch)
                escaped = false
            } else if ch == "\\", quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if ch == q { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
            } else if ch == " " || ch == "\t" {
                if inWord { out.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(ch)
                inWord = true
            }
        }
        if inWord { out.append(word) }
        return out
    }

    /// A file for `browser upload`: its name, type and bytes in base64, read here, where the agent's files are.
    /// Up to 10 MB: it crosses the socket and into the page as text.
    static func uploaded(_ path: String) -> JSONValue {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let data = FileManager.default.contents(atPath: url.path) else { fail("Can't read \(path)") }
        guard data.count <= 10_000_000 else { fail("\(url.lastPathComponent) is over 10 MB") }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .object([
            "name": .string(url.lastPathComponent), "type": .string(type), "data": .string(data.base64EncodedString())
        ])
    }

    /// An address as typed: `localhost:3000` and `127.0.0.1:8080` are http, a bare host is https.
    static func address(_ s: String) -> String {
        if s.contains("://") || s.hasPrefix("about:") { return s }
        return (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" : "https://") + s
    }
}
