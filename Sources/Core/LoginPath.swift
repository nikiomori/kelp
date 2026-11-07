import Foundation
import os

/// The PATH agents need. A daemon started from Finder only has /usr/bin:/bin, while agent CLIs live where the
/// user's shell profile points (~/.local/bin, Homebrew, npm…). Read once from a login shell, plus well-known dirs.
/// Only the daemon reads it (it starts at launch, in the background): the app asks the daemon (`process.which`).
public enum LoginPath {
    /// Given outright (KELP_LOGIN_PATH: tests, where the user's profile must not run), it is the PATH and no shell runs.
    static let shared = Once { ProcessInfo.processInfo.environment["KELP_LOGIN_PATH"] ?? shellPath().map(path) }

    /// The PATH, waiting for the login shell the first time (seconds, with a slow profile).
    public static var value: String { shared.value }

    /// The login shell asked again, for an installer that has just added its folder to the profile (opencode, Grok and
    /// Kimi do): the PATH read at launch doesn't have it. A read that fails or comes back empty keeps the old PATH.
    public static func reread(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        guard ProcessInfo.processInfo.environment["KELP_LOGIN_PATH"] == nil else { return }   // given outright: nothing to read
        reread(shared, from: shellPath(shell: shell))
    }

    static func reread(_ once: Once, from shell: String?) {
        guard let shell, !shell.isEmpty else { return }
        once.replace(path(shell))
    }

    /// Absolute path of `command`, or a message the UI can show as is.
    public static func resolve(_ command: String) throws -> String { try resolve(command, in: value) }

    /// `resolve` for a caller that must stay quick (an in-order call): nil while the login shell is still being read,
    /// instead of waiting for it.
    public static func resolveNow(_ command: String) throws -> String? {
        try shared.ifRead.map { try resolve(command, in: $0) }
    }

    static func resolve(_ command: String, in path: String) throws -> String {
        if command.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw RPCError.invalidParams("\(command) doesn't exist or isn't executable.")
            }
            return command
        }
        for dir in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)") {
            return "\(dir)/\(command)"
        }
        throw RPCError.invalidParams(
            "Couldn't find `\(command)`. Install it, or make sure your shell profile adds it to PATH.")
    }

    /// The shell's PATH, then the daemon's own, then well-known folders that exist.
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

    /// `$SHELL -ilc` prints the PATH the user's terminal would have (interactive too: many put PATH in .zshrc); "" when it
    /// fails or takes over 8 s (a slow or prompting profile must not hold up agents). nil when it couldn't start here (an
    /// in-order call, `Subprocess.quickOnly`): not an answer to keep.
    static func shellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String? {
        let r: Subprocess.Output
        do {
            r = try Subprocess.run(
                [shell, "-ilc", "printf '__KELP__%s__KELP__' \"$PATH\""], cwd: NSHomeDirectory(),
                env: ProcessInfo.processInfo.environment, timeLimit: 8)
        } catch is RPCError { return nil } catch { return "" }   // refused here; no such shell
        let s = String(decoding: r.stdout, as: UTF8.self)
        guard !r.timedOut, let a = s.range(of: "__KELP__"),
            let b = s.range(of: "__KELP__", range: a.upperBound..<s.endIndex)
        else { return "" }
        return String(s[a.upperBound..<b.lowerBound])
    }

    /// A value read once, by the first caller that needs it; the callers meanwhile wait for that read, except through
    /// `ifRead`. A read that gives nil isn't kept: the next caller reads again (the PATH without the shell's until then).
    final class Once: Sendable {
        private let known = OSAllocatedUnfairLock<String?>(initialState: nil)
        private let reading = NSLock()
        private let read: @Sendable () -> String?
        init(_ read: @escaping @Sendable () -> String?) { self.read = read }

        var ifRead: String? { known.withLock { $0 } }

        func replace(_ v: String) { known.withLock { $0 = v } }

        var value: String {
            if let v = ifRead { return v }
            reading.lock()
            defer { reading.unlock() }
            if let v = ifRead { return v }   // read by the caller this one waited for
            guard let v = read() else { return LoginPath.path("") }
            known.withLock { $0 = v }
            return v
        }
    }
}
