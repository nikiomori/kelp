import Core
import Foundation

/// Runs a command the way the user's terminal would (login-shell PATH); `input` goes to its stdin. The daemon runs it
/// (`process.run`): the app starts no programs. `extension`: whose command it is (its folder's name) — refused once
/// that extension is off. A failure to reach the daemon or to start the program is code -1 with the reason as stderr.
/// One of the app's ways to the daemon, beside `AppModel.call`, `tryCall` / `get`, `quiet` and `notify`: here a
/// failure is a result like any other, for the caller to show where it shows the command's output.
package enum Shell {
    package typealias Result = ProcessRun.Result
    package static func run(
        _ app: AppModel, _ command: String, cwd: String, input: String? = nil, timeout: TimeInterval = 60,
        extension id: String? = nil
    ) async -> Result {
        await exec(app, ["/bin/zsh", "-lc", command], cwd: cwd, input: input, timeout: timeout, extension: id)
    }

    /// A program by path (`argv[0]`), with the same PATH and a time limit (stopped then, with what it started).
    package static func exec(
        _ app: AppModel, _ argv: [String], cwd: String = NSHomeDirectory(), input: String? = nil,
        timeout: TimeInterval = 60,
        extension id: String? = nil
    ) async -> Result {
        do {
            return try await app.get(
                ProcessRun(argv: argv, cwd: cwd, stdin: input, timeLimit: timeout, extensionId: id))
        } catch {
            return Result(
                code: -1, stdout: "", stderr: (error as? RPCError)?.message ?? error.localizedDescription,
                timedOut: false)
        }
    }
}
