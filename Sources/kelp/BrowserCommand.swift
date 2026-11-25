import Core
import Foundation

extension Main {
    static let browserUsage = BrowserWords.usage

    /// `browser <action>` drives a page tab in the app, beside the agent's terminal (`UIBrowser`). With no action, the
    /// actions come from stdin, one per line, each answered under its own line, until one fails.
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
                fflush(stdout)   // Flush before an error, which goes to stderr unbuffered.
                // The rest of an eval line is its script as written, so there is no quoting to get through.
                if let js = line.firstMatch(of: /^eval\s+(.+)$/)?.1 {
                    args = []
                    try await browse("eval", js: String(js), c, workspace, json: json)
                } else {
                    args = ShellQuote.words(line)
                    try await browse(args.removeFirst(), c, workspace, json: json)
                }
            }
            return
        }
        try await browse(sub, c, workspace, json: json)
    }

    /// Runs one action and prints its answer, as lines (`browserText`) or as the JSON it came as.
    static func browse(_ sub: String, js: String? = nil, _ client: RPCClient, _ workspace: String?, json: Bool)
        async throws
    {
        guard let action = BrowserAction(rawValue: sub) else { fail("usage: kelp " + browserUsage) }
        if action == .ask, args.isEmpty { fail("browser ask <what the user should do on the page, then hand it back>") }
        var params = js.map { ["js": .string($0)] } ?? browserParams(action)
        if action == .ask { params["text"] = .string(args.joined(separator: " ")) }
        // The session sets whose pointer the user sees on the page, with the agent's name and colour.
        if let session = ProcessInfo.processInfo.environment["KELP_SESSION"] { params["session"] = .string(session) }
        let answer =
            action == .ask
            ? try await client.call(
                UIBrowserAsk(question: params["text"]?.string ?? "", args: .object(params), worktreeId: workspace))
            : try await client.call(UIBrowser(action: action, args: .object(params), worktreeId: workspace))
        if !json, let text = BrowserWords.text(action, BrowserWords.what(params), answer) {
            print(text)
        } else {
            show(answer)
        }
        fflush(stdout)
    }

    /// Returns an action's parameters, read from the words after it (`args`), with the files they name read here.
    static func browserParams(_ action: BrowserAction) -> [String: JSONValue] {
        let files = BrowserWords.Files(
            path: { URL(fileURLWithPath: $0).standardizedFileURL.path },
            read: { FileManager.default.contents(atPath: $0) },
            stdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) })
        do { return try BrowserWords.params(action, &args, files) } catch let wrong as BrowserWords.Wrong {
            fail(wrong.message)
        } catch { fail("\(error)") }
    }
}
