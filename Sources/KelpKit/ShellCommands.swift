import Core
import Foundation

/// Runs a command the way the user's terminal would (with the login-shell PATH), with `input` on its stdin. The daemon
/// runs it (`process.run`), because the app starts no programs. `extension` names the extension whose command it is
/// (its folder's name), and the daemon refuses the command once that extension is off. A failure to reach the daemon
/// or to start the program comes back as code -1 with the reason as stderr.
/// This is one of the app's ways to the daemon, beside `AppModel.call`, `tryCall` / `get`, `quiet` and `notify`. Here
/// a failure is a result like any other, so the caller shows it where it shows the command's output.
package enum Shell {
    package typealias Result = ProcessRun.Result
    package static func run(
        _ app: AppModel, _ command: String, cwd: String, input: String? = nil, timeout: TimeInterval = 60,
        extension id: String? = nil
    ) async -> Result {
        await exec(app, ["/bin/zsh", "-lc", command], cwd: cwd, input: input, timeout: timeout, extension: id)
    }

    /// Runs a program by path (`argv[0]`), with the same PATH and a time limit. When time runs out, the program is
    /// stopped along with what it started.
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
