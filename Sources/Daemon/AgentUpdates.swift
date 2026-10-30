import Foundation
import Core

/// Claude Code installs its updates itself, and a running one stays the version it started as until its /restart, which
/// replaces the program in place: the same pid and terminal, the same conversation, flags and permission mode. Kelp types
/// it for the agent once that loses nothing.
extension Sessions {
    /// On the ticker, every 15 s. One session a round: each reads its conversation and starts its servers again.
    func restartOutdated() {
        let due = nextUpdateCheck.withLock { next -> Bool in
            guard Date() >= next else { return false }
            next = Date().addingTimeInterval(15); return true
        }
        // Its native launcher, whatever comes first on PATH: that's what /restart runs.
        guard due, settings["agents.updateIdle"]?.bool != false, let installed = Paths.real(NSHomeDirectory() + "/.local/bin/claude") else { return }
        for ls in live.all where ls.snapshot.agent == "claude" && Self.outdated(running: Unix.executable(ls.pty.pid), installed: installed) {
            // A tab on screen is being read, and a restart redraws it.
            if ls.restartAgent(into: installed, quiet: ls.isAttached ? 300 : 30) { return }
        }
    }

    /// The launcher points at another version than the one running. Only a native install's versions: one from npm or
    /// Homebrew has no /restart, and a remote agent or one in tmux is ssh or tmux here.
    static func outdated(running: String?, installed: String) -> Bool {
        guard let running else { return false }
        return running != installed && [running, installed].allSatisfy { $0.contains("/claude/versions/") }
    }
}

extension LiveSession {
    /// Types /restart if nothing can be lost: its turn ended (a session that hasn't had one has no conversation to come back
    /// to), nothing runs or is timed to wake it, nothing it asked is open, no text of anyone's is in the box or on its way,
    /// and it has been quiet for `quiet` seconds. Checked and typed under the lock: no key lands in between.
    /// `version`: tried once for each, for a Claude Code without the command (it prints "Unknown command", no more).
    func restartAgent(into version: String, quiet: TimeInterval) -> Bool {
        state.withLock { s in
            guard s.updatedTo != version, s.record.status == .done, !s.parked, s.boxEmpty, s.startedUp, s.pendingPrompts.isEmpty,
                  s.inputsInFlight == 0, s.readyForText(submits: true),
                  Date().timeIntervalSince(s.lastOutputAt ?? s.started) > quiet else { return false }
            s.updatedTo = version
            type("/restart", enter: true, paste: false, &s)
            return true
        }
    }
}
