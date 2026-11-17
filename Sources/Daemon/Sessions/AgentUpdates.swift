import Core
import Foundation
import os

/// Restarts outdated Claude Code sessions. Claude Code installs its updates itself, and a running copy stays the
/// version it started as until its /restart, which replaces the program in place with the same pid and terminal, the
/// same conversation, flags and permission mode. Kelp types /restart for the agent once that loses nothing.
final class AgentUpdates: Sendable {
    private let live: SessionTable, settings: SettingsStore
    private let nextCheck = OSAllocatedUnfairLock(initialState: Date.distantPast)   // `restartOutdated`

    init(live: SessionTable, settings: SettingsStore) {
        self.live = live
        self.settings = settings
    }

    /// Runs on the ticker, every 15 s, and restarts one session a round, because each restart reads its conversation
    /// and starts its servers again.
    /// `installed` is Claude Code's native launcher, whatever comes first on PATH (that's what /restart runs).
    /// `running` returns the program a session's pid runs.
    func restartOutdated(
        now: Date = Date(), installed: () -> String? = { Paths.real(NSHomeDirectory() + "/.local/bin/claude") },
        running: (pid_t) -> String? = { Unix.executable($0) }
    ) {
        let due = nextCheck.withLock { next -> Bool in
            guard now >= next else { return false }
            next = now.addingTimeInterval(15)
            return true
        }
        guard due, settings[SettingKeys.updateIdle], let installed = installed() else { return }
        for ls in live.all
        where ls.snapshot.agent == Session.claudeAgent
            && Self.outdated(running: running(ls.pty.pid), installed: installed)
        {
            // A tab on screen is being read, and a restart redraws it.
            if ls.restartAgent(into: installed, quiet: ls.isAttached ? 300 : 30) { return }
        }
    }

    /// Whether the launcher points at another version than the one running. Only a native install's versions count,
    /// because an install from npm or Homebrew has no /restart, and for a remote agent or one in tmux the program here
    /// is ssh or tmux.
    static func outdated(running: String?, installed: String) -> Bool {
        guard let running else { return false }
        return running != installed && [running, installed].allSatisfy { $0.contains("/claude/versions/") }
    }
}

extension LiveSession {
    /// Types /restart if nothing can be lost: the session's turn ended (a session that hasn't had one has no
    /// conversation to come back to), nothing runs or is timed to wake it, nothing it asked is open, no text of
    /// anyone's is in the box or on its way, and it has been quiet for `quiet` seconds. This is checked and typed under
    /// the lock, so no key lands in between.
    /// Each `version` is tried once, for a Claude Code without the command (it prints "Unknown command", nothing more).
    func restartAgent(into version: String, quiet: TimeInterval) -> Bool {
        state.withLock { st in
            guard st.updatedTo != version, st.record.status == .done, !st.kept.parked, st.kept.boxEmpty, st.startedUp,
                st.pendingPrompts.isEmpty,
                st.inputsInFlight == 0, st.readyForText(submits: true),
                Date().timeIntervalSince(st.lastOutputAt ?? st.started) > quiet
            else { return false }
            st.updatedTo = version
            type("/restart", enter: true, paste: false, &st)
            return true
        }
    }
}
