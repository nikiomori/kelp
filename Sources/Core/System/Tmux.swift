import Foundation

/// tmux sessions as Kelp terminals. The tab runs `tmux new-session -A -s <name>`, which attaches to that session or
/// starts it. tmux keeps the session, so the tab goes back to it after Kelp or its daemon restarts, and closing the
/// tab only detaches. A remote project's tmux runs on its host.
public enum Tmux {
    public struct Session: Codable, Sendable, Equatable {
        public var name: String, windows: Int, attached: Int
        /// When someone last typed in the session or it printed something.
        public var activity: Date
        public init(name: String, windows: Int, attached: Int, activity: Date) {
            self.name = name
            self.windows = windows
            self.attached = attached
            self.activity = activity
        }
    }

    public static func argv(_ name: String) -> [String] { ["tmux", "new-session", "-A", "-s", name] }

    /// Returns the session that a terminal's argv attaches to, or nil for any other program.
    public static func session(_ argv: [String]) -> String? {
        argv.count == 5 && argv.prefix(4).elementsEqual(Self.argv("").prefix(4)) ? argv[4] : nil
    }

    /// Returns a session name tmux keeps as it is. tmux turns ":" and "." into "_" itself, and the tab has to find the
    /// session by its name.
    public static func name(_ name: String) -> String {
        String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).map {
                $0 == ":" || $0 == "." || $0.isNewline ? "_" : $0
            })
    }

    /// Sessions Kelp starts for its own terminals (the `terminal.tmux` setting) are named "kelp-tab-" plus 8 hex
    /// digits, and they end with their tab. All other sessions are the user's, and closing a tab attached to one only
    /// detaches.
    public static func own() -> String { "kelp-tab-" + UUID().uuidString.prefix(8).lowercased() }
    public static func isOwn(_ name: String) -> Bool {
        name.count == 17 && name.hasPrefix("kelp-tab-") && name.dropFirst(9).allSatisfy(\.isHexDigit)
    }
    /// The programs a pane runs when nothing else runs in it.
    public static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    /// The format for `tmux list-sessions -F`, which prints one session per line. It uses colons, not tabs, because
    /// tmux 3.8 prints a tab in -F output as "_", and a session name can't hold a colon (tmux turns ":" and "." into
    /// "_").
    public static let format = "#{session_name}:#{session_windows}:#{session_attached}:#{session_activity}"

    /// Parses what `tmux list-sessions -F format` prints, with the most recently used session first. Lines that aren't
    /// sessions (a host's shell greeting) are skipped.
    public static func parse(_ out: String) -> [Session] {
        out.split(whereSeparator: \.isNewline).compactMap { line -> Session? in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 4, let windows = Int(fields[fields.count - 3]),
                let attached = Int(fields[fields.count - 2]), let activity = Double(fields[fields.count - 1])
            else { return nil }
            let name = fields.dropLast(3).joined(separator: ":")   // The last 3 are numbers, whatever a name may hold.
            guard !name.isEmpty else { return nil }
            return Session(
                name: name, windows: windows, attached: attached, activity: Date(timeIntervalSince1970: activity))
        }.sorted { $0.activity > $1.activity }
    }

    /// Whether `list-sessions` failed only because no tmux server runs there (a server starts with the first session),
    /// or because the server exited while answering (its last session just ended). Either way there are no sessions.
    public static func noServer(_ stderr: String) -> Bool {
        stderr.contains("no server running") || stderr.contains("error connecting to")
            || stderr.contains("server exited unexpectedly")
    }
}
