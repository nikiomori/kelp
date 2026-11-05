import Foundation
import UniformTypeIdentifiers
import Core

extension Main {
    static let browserUsage = """
    browser open <url> [--shared] | snapshot [ref] [--find text] | click <ref> | hover <ref> | type <ref> <text> [--submit]
            | press <key> [ref] | upload <ref> <file>… | dialog accept [text]|dismiss
            | scroll [down|up|top|bottom|<ref>] | back | reload | eval <js> | viewport <WxH>|reset
            | screenshot [file] | wait [--text t] [--selector css] [--timeout 10] | console [--clear] | network [--clear] | info
    """

    /// `browser <action>`: a page tab in the app, beside the agent's terminal, driven from here (`UIBrowser`).
    static func browser(_ sub: String?, _ c: RPCClient) async throws {
        guard let action = sub else { fail("usage: kelp " + browserUsage) }
        var a: [String: JSONValue] = [:]
        switch action {
        case "open":
            a["shared"] = .bool(has("--shared"))
            guard let u = args.first else { fail("browser open <url> [--shared]") }
            a["url"] = .string(address(u))
        case "click", "hover":
            guard let r = args.first else { fail("browser \(action) <ref>") }
            a["ref"] = .string(r)
        case "press":
            guard let k = args.first else { fail("browser press <key> [ref]  (Enter, Escape, Tab, Shift+Tab, ArrowDown, a…)") }
            a["key"] = .string(k)
            if args.count > 1 { a["ref"] = .string(args[1]) }
        case "scroll": a["to"] = .string(args.first ?? "down")
        case "type":
            a["submit"] = .bool(has("--submit"))
            guard args.count >= 2 else { fail("browser type <ref> <text> [--submit]") }
            a["ref"] = .string(args[0]); a["text"] = .string(args.dropFirst().joined(separator: " "))
        case "eval":
            guard !args.isEmpty else { fail("browser eval <js>") }
            a["js"] = .string(args.joined(separator: " "))
        case "screenshot":
            if let f = args.first { a["path"] = .string(URL(fileURLWithPath: f).standardizedFileURL.path) }
        case "wait":
            if let t = flag("--text") { a["text"] = .string(t) }
            if let s = flag("--selector") { a["selector"] = .string(s) }
            if let t = flag("--timeout").flatMap(Double.init) { a["timeout"] = .double(t) }
        case "console", "network": a["clear"] = .bool(has("--clear"))
        case "snapshot":
            if let f = flag("--find") { a["find"] = .string(f) }
            if let r = args.first { a["ref"] = .string(r) }
        case "upload":
            guard args.count >= 2 else { fail("browser upload <ref> <file>…") }
            a["ref"] = .string(args[0])
            a["files"] = .array(args.dropFirst().map(uploaded))
        case "dialog":
            guard let answer = args.first, ["accept", "dismiss"].contains(answer) else { fail("browser dialog accept [text] | dismiss") }
            a["answer"] = .string(answer)
            if args.count > 1 { a["text"] = .string(args.dropFirst().joined(separator: " ")) }
        case "viewport":
            guard let size = args.first else { fail("browser viewport <width>x<height> | reset  (390x844, 768x1024, 1440x900)") }
            a["size"] = .string(size)
        case "info", "back", "reload": break
        default: fail("usage: kelp " + browserUsage)
        }
        let w = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c)
        show(try await c.call(UIBrowser(action: action, args: .object(a), worktreeId: w?.id)))
    }

    /// A file for `browser upload`: its name, type and bytes in base64, read here, where the agent's files are.
    /// Up to 10 MB: it crosses the socket and into the page as text.
    static func uploaded(_ path: String) -> JSONValue {
        let u = URL(fileURLWithPath: path).standardizedFileURL
        guard let data = FileManager.default.contents(atPath: u.path) else { fail("Can't read \(path)") }
        guard data.count <= 10_000_000 else { fail("\(u.lastPathComponent) is over 10 MB") }
        let type = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .object(["name": .string(u.lastPathComponent), "type": .string(type), "data": .string(data.base64EncodedString())])
    }

    /// An address as typed: `localhost:3000` and `127.0.0.1:8080` are http, a bare host is https.
    static func address(_ s: String) -> String {
        if s.contains("://") || s.hasPrefix("about:") { return s }
        return (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" : "https://") + s
    }
}
