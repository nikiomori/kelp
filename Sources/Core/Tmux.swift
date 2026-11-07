import Foundation

/// tmux sessions as Kelp terminals. The tab runs `tmux new-session -A -s <name>`, which attaches to that session or
/// starts it. tmux keeps the session, so the tab goes back to it after Kelp or its daemon restarts, and closing the
/// tab only detaches. A remote project's tmux runs on its host.
public enum Tmux {
    public struct Session: Codable, Sendable, Equatable {
        public var name: String, windows: Int, attached: Int
        /// When someone last typed in it or it printed something.
        public var activity: Date
        public init(name: String, windows: Int, attached: Int, activity: Date) {
            self.name = name
            self.windows = windows
            self.attached = attached
            self.activity = activity
        }
    }

    public static func argv(_ name: String) -> [String] { ["tmux", "new-session", "-A", "-s", name] }

    /// The session a terminal's argv attaches to; nil for any other program.
    public static func session(_ argv: [String]) -> String? {
        argv.count == 5 && argv.prefix(4).elementsEqual(Self.argv("").prefix(4)) ? argv[4] : nil
    }

    /// A name tmux keeps as it is: it turns ":" and "." into "_" itself, and the tab has to find the session by that name.
    public static func name(_ name: String) -> String {
        String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).map {
                $0 == ":" || $0 == "." || $0.isNewline ? "_" : $0
            })
    }

    /// Sessions Kelp starts for terminals of its own (the `terminal.tmux` setting) are named so ("kelp-tab-" and 8 hex
    /// digits): they end with their tab. The rest are the user's, and closing a tab attached to one only detaches.
    public static func own() -> String { "kelp-tab-" + UUID().uuidString.prefix(8).lowercased() }
    public static func isOwn(_ name: String) -> Bool {
        name.count == 17 && name.hasPrefix("kelp-tab-") && name.dropFirst(9).allSatisfy(\.isHexDigit)
    }
    /// What a pane runs when nothing runs in it.
    public static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    /// `tmux list-sessions -F` with this, one session a line. Colons, not tabs: tmux 3.8 prints a tab in -F output as
    /// "_", and a session name can't hold a colon (tmux turns ":" and "." into "_").
    public static let format = "#{session_name}:#{session_windows}:#{session_attached}:#{session_activity}"

    /// What that prints, the last used first. Lines that aren't sessions (a host's shell greeting) are skipped.
    public static func parse(_ out: String) -> [Session] {
        out.split(whereSeparator: \.isNewline).compactMap { line -> Session? in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 4, let windows = Int(fields[fields.count - 3]),
                let attached = Int(fields[fields.count - 2]), let activity = Double(fields[fields.count - 1])
            else { return nil }
            let name = fields.dropLast(3).joined(separator: ":")   // the numbers are the last three, whatever a host's tmux allows in a name
            guard !name.isEmpty else { return nil }
            return Session(
                name: name, windows: windows, attached: attached, activity: Date(timeIntervalSince1970: activity))
        }.sorted { $0.activity > $1.activity }
    }

    /// `list-sessions` failed only because no tmux server runs there (it starts with the first session).
    public static func noServer(_ stderr: String) -> Bool {
        stderr.contains("no server running") || stderr.contains("error connecting to")
    }
}
