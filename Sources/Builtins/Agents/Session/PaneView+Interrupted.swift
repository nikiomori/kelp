import Core
import Foundation
import KelpKit
import TerminalKit

/// How a pane shows an agent whose turn Kelp's going down cut short (`Session.interrupted`): what it printed last, and
/// a bar that says when Kelp closed, without waking it.
extension PaneView {
    /// The words on the bar of a paused session: when Kelp closed, for an agent it cut short.
    static func pausedWords(_ session: Session?) -> String {
        guard let session, session.interrupted, let at = session.interruptedAt else {
            return String(localized: "Paused")
        }
        return String(localized: "Cut short: Kelp closed at \(at.formatted(date: .omitted, time: .shortened))")
    }

    /// The button on the bar of a paused session: Continue for an agent Kelp cut short (`continueCutShort`), which
    /// sends it the line that has it go on, Resume for any other.
    static func pausedButton(_ session: Session?) -> String {
        session?.interrupted == true ? String(localized: "Continue") : String(localized: "Resume")
    }

    /// Has an agent Kelp's going down cut short go on, as Continue on its bar. Returns false for any other session.
    static func continueCutShort(_ session: Session?, _ app: AppModel) -> Bool {
        guard let session, session.interrupted else { return false }
        Task { _ = await app.call(SessionSend(id: session.id, text: Session.goOnText, enter: true)) }
        return true
    }

    /// A terminal that prints the end of the session's log. Unlike `kelp attach`, it doesn't wake the agent. It stays
    /// open, its keys going nowhere, because libghostty takes a command that ends at once for one that failed.
    static func replay(_ session: Session) -> GhosttyTerminalView {
        let printed = replayCommand(session.id, root: Paths.root)
        return GhosttyTerminalView(
            command: "/bin/sh -c " + ShellQuote.word(printed + "; stty raw -echo; exec sleep 2147483647"),
            cwd: session.cwd)
    }

    /// What `replay` prints: the screen cleared of what the login shell printed, then the log's last megabyte (as much
    /// as an attach replays).
    static func replayCommand(_ id: String, root: URL) -> String {
        let log = root.appendingPathComponent("history/\(id).log").path
        return #"printf '\033[H\033[2J\033[3J'; tail -c 1048576 "# + ShellQuote.word(log)
    }
}
