import Foundation
import os

/// The PATH agents need. A daemon started from Finder only has /usr/bin:/bin, while agent CLIs live where the user's
/// shell profile points (~/.local/bin, Homebrew, npm…). It is read once from a login shell, plus well-known dirs.
/// Only the daemon reads it, starting at launch in the background, and the app asks the daemon (`process.which`).
public enum LoginPath {
    /// When KELP_LOGIN_PATH is set (in tests, where the user's profile must not run), it is the PATH and no shell runs.
    static let shared = Once { ProcessInfo.processInfo.environment["KELP_LOGIN_PATH"] ?? shellPath().map(path) }

    /// The PATH. The first read waits for the login shell, which can take seconds with a slow profile.
    public static var value: String { shared.value }

    /// Asks the login shell for the PATH again, after an installer has just added its folder to the profile (opencode,
    /// Grok and Kimi do), because the PATH read at launch doesn't have that folder. A read that fails or comes back
    /// empty keeps the old PATH.
    public static func reread(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        guard ProcessInfo.processInfo.environment["KELP_LOGIN_PATH"] == nil else { return }   // Set: nothing to read.
        reread(shared, from: shellPath(shell: shell))
    }

    static func reread(_ once: Once, from shell: String?) {
        guard let shell, !shell.isEmpty else { return }
        once.replace(path(shell))
    }

    /// Returns the absolute path of `command`, or throws a message the UI can show as it is.
    public static func resolve(_ command: String) throws -> String { try resolve(command, in: value) }

    /// The same as `resolve`, for a caller that must stay quick (an in-order call). It returns nil while the login
    /// shell is still being read, instead of waiting for it.
    public static func resolveNow(_ command: String) throws -> String? {
        try shared.ifRead.map { try resolve(command, in: $0) }
    }

    /// Returns the absolute path of `command`, or nil when it isn't there. It is for asking whether a command is
    /// installed, where no is a normal answer.
    public static func find(_ command: String) -> String? { find(command, in: value) }

    static func find(_ command: String, in path: String) -> String? {
        let fm = FileManager.default
        if command.contains("/") { return fm.isExecutableFile(atPath: command) ? command : nil }
        return path.split(separator: ":").map { "\($0)/\(command)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static func resolve(_ command: String, in path: String) throws -> String {
        if let found = find(command, in: path) { return found }
        if command.contains("/") { throw RPCError.invalidParams("\(command) doesn't exist or isn't executable.") }
        throw RPCError.invalidParams(
            "Couldn't find `\(command)`. Install it, or make sure your shell profile adds it to PATH.")
    }

    /// Returns the shell's PATH, then the daemon's own, then the well-known folders that exist.
    static func path(_ shell: String) -> String {
        let home = NSHomeDirectory()
        let known = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/.claude/local", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let dirs =
            shell.split(separator: ":").map(String.init)
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + known.filter { FileManager.default.fileExists(atPath: $0) }
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Returns the PATH the user's terminal would have, printed by `$SHELL -ilc`. The shell is interactive too, because
    /// many people set PATH in .zshrc. Returns "" when the shell fails or takes over 8 s, because a slow or prompting
    /// profile must not hold up agents. Returns nil when it couldn't start here (an in-order call,
    /// `Subprocess.quickOnly`), which is not an answer to keep.
    static func shellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String? {
        let result: Subprocess.Output
        do {
            result = try Subprocess.run(
                [shell, "-ilc", "printf '__KELP__%s__KELP__' \"$PATH\""], cwd: NSHomeDirectory(),
                env: ProcessInfo.processInfo.environment, timeLimit: 8)
        } catch is RPCError { return nil } catch { return "" }   // Refused here, or no such shell.
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard !result.timedOut, let start = output.range(of: "__KELP__"),
            let end = output.range(of: "__KELP__", range: start.upperBound..<output.endIndex)
        else { return "" }
        return String(output[start.upperBound..<end.lowerBound])
    }

    /// A value read once, by the first caller that needs it. Other callers wait for that read meanwhile, unless they
    /// use `ifRead`. A read that gives nil isn't kept, so the next caller reads again, and until then the PATH lacks
    /// the shell's part.
    final class Once: Sendable {
        private let known = OSAllocatedUnfairLock<String?>(initialState: nil)
        private let reading = NSLock()
        private let read: @Sendable () -> String?
        init(_ read: @escaping @Sendable () -> String?) { self.read = read }

        var ifRead: String? { known.withLock { $0 } }

        func replace(_ path: String) { known.withLock { $0 = path } }

        var value: String {
            if let found = ifRead { return found }
            reading.lock()
            defer { reading.unlock() }
            if let found = ifRead { return found }   // The caller this one waited for has read it.
            guard let found = read() else { return LoginPath.path("") }
            known.withLock { $0 = found }
            return found
        }
    }
}
