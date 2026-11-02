import Foundation
import Core

extension Main {
    /// `edit [--wait] <file>`: an agent's external editor (VISUAL), a tab in Kelp. Ends when the tab closes; the agent then
    /// reads the file. With no terminal it fails at once: a tool running `git commit` must not hang on a tab nobody sees.
    static func edit(_ sub: String?, _ c: RPCClient) async throws {
        _ = has("--wait")
        guard let name = sub.flatMap({ $0 == "--wait" ? nil : $0 }) ?? args.first else { fail("edit [--wait] <file>") }
        guard isatty(STDIN_FILENO) != 0 else { fail("kelp edit opens a tab and waits for it: it needs a terminal") }
        let path = URL(fileURLWithPath: name).standardizedFileURL.path, done = path + Prompts.done
        let fm = FileManager.default
        if fm.fileExists(atPath: done) { try fm.removeItem(atPath: done) }
        let session = ProcessInfo.processInfo.environment["KELP_SESSION"]
        let worktree = session == nil ? nil : try await c.call(SessionList()).first { $0.id == session }?.worktreeId
        let shown = try await c.call(UIOpen(uri: "prompt:" + Prompts.uriBody(path), focus: true, worktreeId: worktree))
        guard shown.delivered > 0 else { fail("Kelp's window isn't open") }
        var beats = 0
        while !fm.fileExists(atPath: done) {
            try await Task.sleep(for: .milliseconds(200))
            beats += 1
            // The window went: nobody will close the tab. The agent goes on with the text it had.
            if beats % 10 == 0, try await c.call(UIStateGet()) == .object([:]) { return }
        }
        try fm.removeItem(atPath: done)
    }
}
