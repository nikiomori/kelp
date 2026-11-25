import Agents
import Core
import Foundation

/// Agents whose turn was cut short because Kelp went down (`Session.interruptedAt`): how they are marked, and how they
/// go on by themselves with `SettingKeys.resumeAfterCrash`. The window's Continue All and Continue send
/// `Session.goOnText` (`session.send`), which wakes each.
enum Interruptions {
    /// The pause between two agents going on, so a dozen don't start at the same moment.
    static let gap: TimeInterval = 1

    /// Whether Kelp going down now cuts `session`'s turn short: an agent at work that a wake brings back. A remote
    /// agent lives on in its tmux session, and anything at rest has nothing to go on with.
    static func cutShort(_ session: Session, _ manifests: [AgentManifest]) -> Bool {
        session.status == .working && session.isAgent && session.tmux == nil && Sessions.resumable(session, manifests)
    }

    /// Marks `session` as cut short at `at`, and unread, so its row says so until it is looked at.
    static func interrupt(_ session: inout Session, at: Date) {
        session.interruptedAt = at
        session.unread = true
    }

    /// Settles a session the last daemon run left: a resumable one comes back paused, the rest as exited, and the old
    /// run's progress, which won't move any more, goes. An agent whose record still says it was at work was lost to a
    /// crash, and is marked cut short; a daemon that stopped marked its agents itself (`markWorking`).
    static func settle(_ session: inout Session, _ manifests: [AgentManifest], root: URL) {
        if cutShort(session, manifests) { interrupt(&session, at: lastHeard(session, root: root)) }
        session.status = Sessions.resumable(session, manifests) ? .paused : .exited
        session.progress = nil
    }

    /// When the last daemon stopped hearing from a session it lost without stopping (a crash): when its log was last
    /// written, or else when its status last changed.
    static func lastHeard(_ session: Session, root: URL) -> Date {
        var info = stat()
        let log = root.appendingPathComponent("history/\(session.id).log").path
        guard stat(log, &info) == 0 else { return session.statusAt ?? session.createdAt }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Marks the agents at work as cut short, before the daemon stops them all (`Daemon.stop`).
    static func markWorking(_ live: [LiveSession], _ manifests: [AgentManifest]) {
        let now = Date()
        for ls in live where cutShort(ls.snapshot, manifests) { _ = ls.update { interrupt(&$0, at: now) } }
    }

    /// Has every interrupted agent go on, oldest first, one at a time with `gap` between them, as a new daemon starts
    /// with the setting on. It returns at once; the wakes happen on a thread of their own.
    static func resumeAll(_ sessions: Sessions) {
        let all = Log.store.attempt("reading the sessions to continue") { try sessions.store.sessions() } ?? []
        let cut = all.filter { $0.interruptedAt != nil && sessions.isPaused($0) }.sorted { $0.createdAt < $1.createdAt }
        guard !cut.isEmpty else { return }
        Thread.detachNewThread {
            for (index, session) in cut.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: gap) }
                // One the user woke meanwhile (opened, sent to) has lost its mark, and isn't told twice.
                let still = Log.store.attempt("reading \(session.id)") { try sessions.store.session(session.id) }
                guard still??.interruptedAt != nil else { continue }
                Log.session.attempt("continuing \(session.id) after Kelp went down") {
                    try sessions.withInput(session.id) { try $0.submit(Session.goOnText, enter: true) }
                }
            }
        }
    }
}
