import AgentData
import Core
import Foundation
import os

// Codex's limits, asked of codex app-server (its /status, not /usage) and read from its session logs.

extension AgentUsage {
    static let codexEvery: TimeInterval = 600

    /// Refreshes Codex's limits as its /status shows them, asked of `codex app-server` every 10 minutes (and half a
    /// minute after a turn). That spends no tokens and opens no TUI, so no startup question (trust this folder? these
    /// hooks?) stands in the way. It never uses Codex's `/usage`, because there it spends a limit reset.
    /// Limit: only the default account is asked (CODEX_HOME); account profiles keep what their sessions logged.
    func refreshCodexIfStale() {
        guard readsPlans else { return }
        let start: Bool = codexLive.withLock { live in
            guard !live.running, Date().timeIntervalSince(live.at) > Self.codexEvery else { return false }
            live.running = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let limits = LoginPath.find("codex").flatMap {
                Self.codexLimits(path: $0, open: self?.openProbes)
            }
            self?.codexLive.withLock { live in
                if let limits { live.limits = limits }
                live.at = Date()
                live.running = false
            }
        }
    }

    /// Asks one `account/rateLimits/read`.
    static func codexLimits(path: String, open: OpenProbes? = nil) -> CodexLimits? {
        let answer = askCodex(path: path, method: "account/rateLimits/read", open: open)
        let limits = CodexUsage.limits(rateLimits: (answer?["result"] as? [String: Any])?["rateLimits"], at: Date())
        if limits == nil {
            Log.session.error("codex app-server gave no limits: \(answer.map { "\($0)" } ?? "no answer in 20 s")")
        }
        return limits
    }

    /// Asks one question of `codex app-server` started with `args` (`-c` pairs) and returns its answer (result or
    /// error), or nil if none came. The app server quits as soon as its input closes, before answering, so it gets a
    /// terminal like the /usage probes and is stopped once it has answered. `until` names a notification that says the
    /// work asked for is done (an import's). That notification is returned instead of the result, though an error is
    /// still the answer.
    static func askCodex(
        path: String, args: [String] = [], method: String, params: String? = nil, open: OpenProbes? = nil,
        within seconds: TimeInterval = 20, until notification: String? = nil
    ) -> [String: Any]? {
        askCodex(
            argv: [path, "app-server"] + args, method: method, params: params, open: open, within: seconds,
            until: notification)
    }

    /// The same, with `argv` starting the app server (ssh running it on a host, say).
    static func askCodex(
        argv: [String], method: String, params: String? = nil, open: OpenProbes? = nil,
        within seconds: TimeInterval = 20, until notification: String? = nil
    ) -> [String: Any]? {
        let out = ScreenBuffer()
        let pty: PTY
        do {
            pty = try PTY(argv: argv, cwd: NSTemporaryDirectory(), env: ["PATH": LoginPath.value])
        } catch {
            Log.session.error("codex app-server didn't start: \(error)")
            return nil
        }
        let exited = OSAllocatedUnfairLock(initialState: false)
        pty.onOutput = { out.append($0) }
        pty.onExit = { _ in exited.withLock { $0 = true } }   // exited unanswered (no Codex there): stop waiting
        pty.start()
        open?.add(pty)
        defer {
            open?.remove(pty)
            pty.terminate()
        }
        let ask = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"kelp","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"\#(method)""# + (params.map { #","params":\#($0)"# } ?? "") + "}"
        ]
        pty.write(Data((ask.joined(separator: "\n") + "\n").utf8))
        var answer: [String: Any]?
        // The terminal echoes the questions back: only an answer has a result or an error.
        _ = out.wait(seconds) { text in
            answer = text.split(whereSeparator: \.isNewline).lazy.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            .first { message in
                message["id"] as? Int == 2 && message["error"] != nil
                    || notification.map { message["method"] as? String == $0 }
                        ?? (message["id"] as? Int == 2 && message["result"] != nil)
            }
            return answer != nil || exited.withLock { $0 }
        }
        return answer
    }
}
