import Foundation
import Core

extension Main {
    static let browserUsage = """
    browser open <url> [--shared] | snapshot | click <ref> | type <ref> <text> [--submit] | eval <js>
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
        case "click":
            guard let r = args.first else { fail("browser click <ref>") }
            a["ref"] = .string(r)
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
        case "snapshot", "info": break
        default: fail("usage: kelp " + browserUsage)
        }
        let w = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c)
        show(try await c.call(UIBrowser(action: action, args: .object(a), worktreeId: w?.id)))
    }

    /// An address as typed: `localhost:3000` and `127.0.0.1:8080` are http, a bare host is https.
    static func address(_ s: String) -> String {
        if s.contains("://") || s.hasPrefix("about:") { return s }
        return (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" : "https://") + s
    }
}
