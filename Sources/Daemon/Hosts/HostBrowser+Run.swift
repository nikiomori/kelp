import Core
import Foundation
import os

/// What a host's `kelp browser` does that the one on this Mac doesn't: its localhost is the host's (the port is
/// forwarded here, and the page's other loads go through the host), and the files it names or gets are on the host
/// (a file to upload is read there, a screenshot, a recording or a download is copied there).
extension HostBrowser {
    /// Runs the words of one request and returns the exit code. With no words, stdin holds the steps, one a line, each
    /// answered under its own line, until one fails.
    func run(_ session: String, _ request: Request, _ say: Say) -> Int32 {
        guard var channel = channel(session) else {
            say.error("This session has ended in Kelp: kelp browser works again once it runs there.")
            return 1
        }
        // Kelp's folder on the host holds the socket (`HostKelp.setup`). A session taken over from the kelpd before
        // this one learns it here.
        let dir = (request.socket as NSString).deletingLastPathComponent
        if dir.hasPrefix("/tmp/kelp-") { channel.dir = dir }
        guard request.words.isEmpty || request.words == ["--json"] else {
            return one(session, channel, request, say) ? 0 : 1
        }
        let json = request.words == ["--json"]
        let lines = request.stdin.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
            say.error("usage: kelp " + BrowserWords.usage)
            return 1
        }
        for line in lines where !line.isEmpty && !line.hasPrefix("#") {
            say.out("› " + line)
            // The rest of an eval line is its script as written, so there is no quoting to get through.
            let script = line.firstMatch(of: /^eval\s+(.+)$/).map { String($0.1) }
            let words = script == nil ? ShellQuote.words(line) : ["eval", "-"]
            var step = request
            (step.words, step.stdin) = ((json ? ["--json"] : []) + words, script ?? "")
            guard one(session, channel, step, say) else {
                return 1
            }
        }
        return 0
    }

    /// Runs one action as the CLI does (`Main.browse`), the host's way. Returns false when it failed, as it said.
    private func one(_ session: String, _ channel: Channel, _ request: Request, _ say: Say) -> Bool {
        var words = request.words
        let (cwd, stdin) = (request.cwd, request.stdin)
        let json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        guard let first = words.first, let action = BrowserAction(rawValue: first) else {
            say.error("usage: kelp " + BrowserWords.usage)
            return false
        }
        words.removeFirst()
        let remote = channel.remote
        do {
            if action == .ask, words.isEmpty {
                throw BrowserWords.Wrong("browser ask <what the user should do on the page, then hand it back>")
            }
            let files = BrowserWords.Files(
                path: { Self.path($0, in: cwd) },
                read: { path in
                    Log.session.attempt("reading \(path) on \(remote.host)") {
                        try remote.run("head -c \(BrowserWords.uploadLimit + 1) < " + ShellQuote.word(path))
                    }
                }, stdin: { stdin })
            var params = try BrowserWords.params(action, &words, files)
            if action == .ask { params["text"] = .string(words.joined(separator: " ")) }
            let plan = try before(action, &params, session, channel)
            let method: any Answered =
                action == .ask
                ? UIBrowserAsk(
                    question: params["text"]?.string ?? "", args: .object(params), worktreeId: worktree(session))
                : UIBrowser(action: action, args: .object(params), worktreeId: worktree(session))
            let answer = after(action, try call(session, method, page: plan.page), plan, session, channel)
            if !json, let text = BrowserWords.text(action, BrowserWords.what(params), answer) {
                say.out(text + (plan.note.map { "\n" + $0 } ?? ""))
            } else if case .string(let text) = answer {
                say.out(text)
            } else if answer != .null, let text = Self.pretty(answer) {
                say.out(text)
            }
            return true
        } catch let wrong as BrowserWords.Wrong {
            say.error(wrong.message)
        } catch {
            say.error("error: " + error.rpcMessage)
        }
        return false
    }

    /// The JSON of an answer as `kelp --json` prints it.
    static func pretty(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return Log.session.attempt("printing an answer") { try encoder.encode(value) }.map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// A path as typed in the host's folder `cwd`, made whole there.
    static func path(_ typed: String, in cwd: String) -> String {
        URL(fileURLWithPath: typed, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }

    /// Answers the method as the session's agent, waiting here (this is the request's own thread, not the pool).
    private func call(_ session: String, _ method: any Answered, page: JSONValue?) throws -> JSONValue {
        guard let answer = answer.withLock({ $0 }) else { throw RPCError.internalError("Kelp is starting.") }
        let result = OSAllocatedUnfairLock<Result<JSONValue, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let got = await Result { try await Self.$page.withValue(page) { try await answer(session, method) } }
            result.withLock { $0 = got }
            done.signal()
        }
        done.wait()
        guard let got = result.withLock({ $0 }) else { throw RPCError.internalError("No answer.") }
        return try got.get()
    }

    // MARK: before and after

    /// What `before` decided for the answer: what the page is told when it opens (`HostBrowser.page`), where a
    /// screenshot goes on the host, and a line to add.
    struct Plan {
        var page: JSONValue?, there: String?, note: String?
    }

    /// Changes an action's parameters for a page driven from the host.
    private func before(
        _ action: BrowserAction, _ params: inout [String: JSONValue], _ session: String, _ channel: Channel
    ) throws -> Plan {
        let remote = channel.remote
        switch action {
        case .open:
            if params["shared"]?.bool == true {
                throw BrowserWords.Wrong(
                    "--shared isn't there from a host: it would hand the user's logged-in browser on the Mac to this "
                        + "host. Open the page without it.")
            }
            let url = params["url"]?.string ?? ""
            if url.hasPrefix("preview:") {
                throw BrowserWords.Wrong(
                    "preview: shows a file on the Mac. Serve the folder over http here (python3 -m http.server 8000) "
                        + "and open localhost:8000.")
            }
            var note: String?
            if let wid = worktree(session) {
                if Self.isLoopback(url) {
                    let here = forwards.forward(url: url, in: wid, remote)
                    params["url"] = .string(here)
                    let (asked, got) = (URLComponents(string: url)?.port, URLComponents(string: here)?.port)
                    if let asked, let got, asked != got {
                        note =
                            "(port \(asked) on \(remote.host) is \(got) on the Mac, where the page draws: "
                            + "its origin is localhost:\(got))"
                    }
                }
                forwardProject(wid, remote)
            }
            guard let proxy = socks(remote) else {
                throw RPCError.internalError(
                    "Kelp couldn't take the page's network through \(remote.host) (ssh -D on its connection).")
            }
            let page: JSONValue = .object([
                "host": .string(remote.host), "proxy": .int(proxy),
                "ports": .array(forwards.mapping(host: remote.host).map { .int($0.here) })
            ])
            return Plan(page: page, note: note)
        case .screenshot:
            // The app writes the picture here, and it is copied to the host (`after`).
            defer { params["path"] = nil }
            return Plan(there: params["path"]?.string)
        case .record where params["stop"] == nil:
            let there = params["path"]?.string ?? channel.dir + "/shots/kelp-recording-\(Self.stamp()).mp4"
            let ext = (there as NSString).pathExtension.lowercased()
            let here =
                NSTemporaryDirectory() + "kelp-host-\(Self.stamp()).\(["gif", "mov"].contains(ext) ? ext : "mp4")"
            params["path"] = .string(here)
            recording(session, (here, there))
        default: break
        }
        return Plan()
    }

    /// Changes an answer for the host: files that came here go there, and this Mac's ports read as the host's.
    private func after(
        _ action: BrowserAction, _ answer: JSONValue, _ plan: Plan, _ session: String, _ channel: Channel
    ) -> JSONValue {
        guard case .object(var fields) = answer else { return answer }
        let remote = channel.remote
        switch action {
        case .screenshot:
            if let here = fields["path"]?.string {
                let there = plan.there ?? channel.dir + "/shots/" + (here as NSString).lastPathComponent
                fields["path"] = .string(copy(here, to: there, remote) ?? here)
            }
        case .record:
            if fields["recording"]?.bool == true {
                fields["path"] = recording(session).map { .string($0.there) } ?? fields["path"]
            } else if let here = fields["path"]?.string {
                let there = recording(session)?.there ?? channel.dir + "/shots/" + (here as NSString).lastPathComponent
                recording(session, nil)
                fields["path"] = .string(copy(here, to: there, remote) ?? here)
            }
        default: break
        }
        if let downloads = fields["downloads"]?.array {
            fields["downloads"] = .array(downloads.map { .string(downloaded($0.string ?? "", channel)) })
        }
        let ports = forwards.mapping(host: remote.host)
        for key in ["url", "page", "new"] {
            if let text = fields[key]?.string { fields[key] = .string(Self.hostView(text, ports)) }
        }
        return .object(fields)
    }

    /// A download line (`/…/kelp-downloads/a.zip (done, 120 bytes)`) once its file is copied to the host's downloads.
    private func downloaded(_ line: String, _ channel: Channel) -> String {
        guard let done = line.range(of: " (done, ") else { return line }
        let here = String(line[..<done.lowerBound])
        let there = channel.dir + "/downloads/" + (here as NSString).lastPathComponent
        guard let copied = copy(here, to: there, channel.remote) else { return line }
        return copied + line[done.lowerBound...]
    }

    /// Copies a file the app wrote here to `there` on the host, then removes it here. Returns the path there, or nil
    /// when it didn't go (the file stays here then).
    private func copy(_ here: String, to there: String, _ remote: RemoteHost) -> String? {
        guard let data = FileManager.default.contents(atPath: here) else { return nil }
        let quoted = ShellQuote.word(there)
        let sent = Log.session.attempt("copying \((here as NSString).lastPathComponent) to \(remote.host)") {
            try remote.run(
                "mkdir -p \"$(dirname \(quoted))\" && cat > \(quoted)", stdin: data, timeLimit: 300)
        }
        guard sent != nil else { return nil }
        Log.session.attempt("removing \(here)") { try FileManager.default.removeItem(atPath: here) }
        return there
    }

    /// Brings the other ports the project listens on, so the page's calls to its own API on another port arrive.
    private func forwardProject(_ wid: String, _ remote: RemoteHost) {
        guard let worktree = store.look("the workspace \(wid)", { try $0.worktree(wid) }) ?? nil else { return }
        for port in forwards.ports(worktree, remote, sessions: []) where port.here == nil {
            _ = Log.session.attempt("forwarding port \(port.port)") {
                try forwards.forward("localhost:\(port.port)", in: wid, remote)
            }
        }
    }

    /// Whether an address is a loopback one, which the host means as its own.
    static func isLoopback(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }

    /// Text with this Mac's forwarded ports put back as the host's (`localhost:3001` → `localhost:3000`), and a note
    /// when they differ, so the agent reads its own addresses.
    static func hostView(_ text: String, _ ports: [(here: Int, target: String)]) -> String {
        var out = text
        for port in ports {
            let there = port.target.split(separator: ":").last.map(String.init) ?? ""
            guard there != String(port.here) else { continue }
            let host = port.target.hasPrefix("127.0.0.1") ? "127.0.0.1" : "localhost"
            out = out.replacingOccurrences(
                of: "://localhost:\(port.here)", with: "://\(host):\(there)")
        }
        return out
    }

    static func stamp() -> String { String(UUID().uuidString.prefix(6)).lowercased() }
}
