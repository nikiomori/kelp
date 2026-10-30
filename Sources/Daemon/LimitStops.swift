import Foundation
import Core
import Agents

/// A turn a plan limit stopped: the record says so until the agent does anything else (`State.sync`), and at the time it was
/// told it goes on by itself. Here in the daemon, on the ticker: Kelp's window can be closed by then.
extension LiveSession {
    /// A hook said so; the Stop that ended the turn comes right after.
    func hitLimit(_ r: ClaudeLimits.Reading) {
        state.withLock { s in
            s.record.limitHit = LimitHit(kind: r.kind, resets: r.resets)
            emit(s.record)
        }
    }

    func continueAt(_ at: Date?) {
        state.withLock { s in
            guard at == nil || s.record.limitHit != nil else { return }
            s.record.continueAt = at
            emit(s.record)
        }
    }

    /// Once it's time and nothing's in the way (a half-typed line waits for its author), inside `state.withLock`. One that
    /// went on by itself (Claude Code can) has lost its `continueAt` by then, so it isn't told twice.
    func continueIfDue(_ s: inout State) {
        guard let at = s.record.continueAt, Date() >= at, !s.letGo, s.pendingPrompts.isEmpty, s.readyForText(submits: true) else { return }
        s.record.continueAt = nil
        type("continue", enter: true, paste: false, &s)
        emit(s.record)
    }
}
