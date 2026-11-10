import Core
import Foundation
import UniformTypeIdentifiers

extension Main {
    static let browserUsage = """
        browser open <url> [--shared] | snapshot [ref] [--find text] | click <ref> | hover <ref> | type <ref> <text> [--submit]
                | drag <ref> <onto-ref|css> | press <key> [ref] | upload <ref> <file>… | dialog accept [text]|dismiss
                | scroll [down|up|top|bottom|<ref>] | back | reload | eval <js> | viewport <WxH>|reset
                | screenshot [file] | wait [--text t] [--selector css] [--timeout 10] | console [--clear] | network [--clear] | info
        """

    /// `browser <action>`: a page tab in the app, beside the agent's terminal, driven from here (`UIBrowser`).
    static func browser(_ sub: String?, _ c: RPCClient) async throws {
        guard let action = sub.flatMap(BrowserAction.init) else { fail("usage: kelp " + browserUsage) }
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
            guard !args.isEmpty else { fail("browser eval <js>") }
            params["js"] = .string(args.joined(separator: " "))
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
        let workspace = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, client: c)
        show(try await c.call(UIBrowser(action: action.rawValue, args: .object(params), worktreeId: workspace?.id)))
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
