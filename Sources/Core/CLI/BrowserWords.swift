import Foundation
import UniformTypeIdentifiers

/// `kelp browser`'s words read into an action's parameters, and its answer printed as lines. The `kelp` on this Mac
/// and kelpd, for the `kelp` on a host (`HostBrowser`), read and print them the same way.
public enum BrowserWords {
    public static let usage = """
        browser open <url> [--shared] | snapshot [ref] [--find text] | click <ref> | hover <ref> | type <ref> <text> [--submit]
                | drag <ref> <onto-ref|css> | press <key> [ref] | upload <ref> <file>… | dialog accept [text]|dismiss
                | scroll [down|up|top|bottom|<ref>] | back | reload | eval <js>|- | viewport <WxH>|reset
                | screenshot [file] | record [file.mp4|file.gif] | record stop
                | wait [--text t] [--selector css] [--timeout 10] | console [--clear] | network [--clear] | info
                | ask <what the user should do on the page>
                [--json] · no action: one a line from stdin (kelp browser <<'EOF' … EOF)
        """

    /// Words that don't make a command: what to say instead.
    public struct Wrong: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Where the files a command names are, as the machine the agent runs on sees them.
    public struct Files {
        /// The absolute path of a path as typed.
        public var path: (String) -> String
        /// A file for `upload`: its bytes, or nil when it can't be read.
        public var read: (String) throws -> Data?
        /// The script of `eval -`.
        public var stdin: () -> String
        public init(
            path: @escaping (String) -> String, read: @escaping (String) throws -> Data?,
            stdin: @escaping () -> String
        ) {
            self.path = path
            self.read = read
            self.stdin = stdin
        }
    }

    /// Returns an action's parameters, read from the words after it. A flag is taken out of `words` wherever it stands.
    public static func params(_ action: BrowserAction, _ words: inout [String], _ files: Files) throws -> [String:
        JSONValue]
    {
        func has(_ name: String) -> Bool {
            guard let index = words.firstIndex(of: name) else { return false }
            words.remove(at: index)
            return true
        }
        func flag(_ name: String) -> String? {
            guard let index = words.firstIndex(of: name), index + 1 < words.count else { return nil }
            defer { words.removeSubrange(index...index + 1) }
            return words[index + 1]
        }
        var params: [String: JSONValue] = [:]
        switch action {
        case .open:
            params["shared"] = .bool(has("--shared"))
            guard let url = words.first else { throw Wrong("browser open <url> [--shared]") }
            params["url"] = .string(address(url))
        case .click, .hover:
            guard let ref = words.first else { throw Wrong("browser \(action) <ref>") }
            params["ref"] = .string(ref)
        case .press:
            guard let key = words.first else {
                throw Wrong("browser press <key> [ref]  (Enter, Escape, Tab, Shift+Tab, ArrowDown, a…)")
            }
            params["key"] = .string(key)
            if words.count > 1 { params["ref"] = .string(words[1]) }
        case .drag:
            guard words.count == 2 else { throw Wrong("browser drag <ref> <onto-ref | css selector>") }
            params["ref"] = .string(words[0])
            params["onto"] = .string(words[1])
        case .scroll: params["to"] = .string(words.first ?? "down")
        case .type:
            params["submit"] = .bool(has("--submit"))
            guard words.count >= 2 else { throw Wrong("browser type <ref> <text> [--submit]") }
            params["ref"] = .string(words[0])
            params["text"] = .string(words.dropFirst().joined(separator: " "))
        case .eval:
            // `eval -` reads the script from stdin as written, because a heredoc keeps the shell off its quotes.
            params["js"] = .string(words == ["-"] ? files.stdin() : words.joined(separator: " "))
        case .screenshot:
            if let file = words.first { params["path"] = .string(files.path(file)) }
        case .record:
            if words.first == "stop" {
                params["stop"] = .bool(true)
            } else if let file = words.first {
                params["path"] = .string(files.path(file))
            }
        case .wait:
            if let text = flag("--text") { params["text"] = .string(text) }
            if let selector = flag("--selector") { params["selector"] = .string(selector) }
            if let timeout = flag("--timeout").flatMap(Double.init) { params["timeout"] = .double(timeout) }
        case .console, .network: params["clear"] = .bool(has("--clear"))
        case .snapshot:
            if let find = flag("--find") { params["find"] = .string(find) }
            if let ref = words.first { params["ref"] = .string(ref) }
        case .upload:
            guard words.count >= 2 else { throw Wrong("browser upload <ref> <file>…") }
            params["ref"] = .string(words[0])
            params["files"] = .array(try words.dropFirst().map { try uploaded($0, files) })
        case .dialog:
            guard let answer = words.first, ["accept", "dismiss"].contains(answer) else {
                throw Wrong("browser dialog accept [text] | dismiss")
            }
            params["answer"] = .string(answer)
            if words.count > 1 { params["text"] = .string(words.dropFirst().joined(separator: " ")) }
        case .viewport:
            guard let size = words.first else {
                throw Wrong("browser viewport <width>x<height> | reset  (390x844, 768x1024, 1440x900)")
            }
            params["size"] = .string(size)
        case .info, .back, .reload, .ask: break
        }
        if case .eval = action, params["js"]?.string?.isEmpty != false {
            throw Wrong("browser eval <js> | eval - (from stdin)")
        }
        return params
    }

    /// Reads a file for `browser upload` where the agent's files are, as its name, type and bytes in base64. It allows
    /// up to 10 MB, because the file crosses the socket and goes into the page as text.
    static func uploaded(_ typed: String, _ files: Files) throws -> JSONValue {
        let path = files.path(typed), name = (path as NSString).lastPathComponent
        guard let data = try files.read(path) else { throw Wrong("Can't read \(typed)") }
        guard data.count <= uploadLimit else { throw Wrong("\(name) is over 10 MB") }
        let type =
            UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .object(["name": .string(name), "type": .string(type), "data": .string(data.base64EncodedString())])
    }
    public static let uploadLimit = 10_000_000

    /// Returns an answer as an agent reads it at a glance: what was done to what and what came of it
    /// (`click e2 button "Idle" → nothing changed`), or where the page is, followed by the page's questions, downloads,
    /// and the lines it brought. Nil for an answer without that shape (a snapshot's text, eval's value), which is
    /// printed as it came.
    public static func text(_ action: BrowserAction, _ what: String, _ answer: JSONValue) -> String? {
        guard action != .eval, case .object(let fields) = answer else { return nil }   // Eval's value is the page's.
        if action == .screenshot { return fields["path"]?.string }
        if action == .record, let path = fields["path"]?.string {
            return fields["recording"]?.bool == true ? "recording → \(path) · kelp browser record stop ends it" : path
        }
        let page = "page \(ShellQuote.doubleQuoted(fields["title"]?.string ?? "")) \(fields["url"]?.string ?? "")"
        var lines: [String]
        switch action {
        case .ask:
            let said =
                switch fields["answer"]?.string {
                case "allow": "the user is done: the page is yours again"
                case "deny": "the user won't: the page stays theirs until they hand it back"
                case "gone": "asked no more: the page stays the user's until they hand it back"
                default: "no answer yet: the page stays the user's (kelp browser ask again waits more)"
                }
            lines = [said, page]
        case .open, .reload, .back, .info, .viewport, .wait:
            let found = action == .wait ? "shown · " : ""
            lines = [found + page + (fields["viewport"]?.string.map { " · viewport \($0)" } ?? "")]
        default:
            let came = [
                fields["upload"]?.string, fields["shows"]?.string.map { "shows " + ShellQuote.doubleQuoted($0) },
                fields["scroll"]?.string.map { "at " + $0 },
                fields["change"]?.string.map { $0 == "new page" ? "new " + page : $0 }
            ].compactMap { $0 }
            let head = [action.rawValue, what, fields["element"]?.string ?? ""].filter { !$0.isEmpty }.joined(
                separator: " ")
            lines = [head + " → " + (came.isEmpty ? "done" : came.joined(separator: ", "))]
        }
        if fields["loading"]?.bool == true { lines.append("(still loading)") }
        if let error = fields["error"]?.string { lines.append("failed: " + error) }
        lines += (fields["dialogs"]?.array ?? []).compactMap(\.string).map { "dialog: " + $0 }
        lines += (fields["downloads"]?.array ?? []).compactMap(\.string).map { "download: " + $0 }
        if let shown = fields["page"]?.string ?? fields["new"]?.string, !shown.isEmpty { lines.append(shown) }
        return lines.joined(separator: "\n")
    }

    /// What an answer is about, for its line: the key pressed and the element (`press Enter e3`).
    public static func what(_ params: [String: JSONValue]) -> String {
        [params["key"]?.string, params["ref"]?.string ?? params["to"]?.string].compactMap { $0 }.joined(separator: " ")
    }

    /// Returns the URL for an address as typed. `localhost:3000` and `127.0.0.1:8080` become http, and a bare host
    /// becomes https.
    public static func address(_ typed: String) -> String {
        if typed.contains("://") || typed.hasPrefix("about:") || typed.hasPrefix("preview:") { return typed }
        return (typed.hasPrefix("localhost") || typed.first?.isNumber == true ? "http://" : "https://") + typed
    }
}
