import Agents
import Core
import Foundation

/// A turn a plan limit stopped: the record says so until the agent does anything else (`State.sync`), and at the time it was
/// told it goes on by itself. Here in the daemon, on the ticker: Kelp's window can be closed by then.
extension LiveSession {
    /// A hook said so; the Stop that ended the turn comes right after.
    func hitLimit(_ reading: ClaudeLimits.Reading) {
        state.withLock { state in
            state.record.limitHit = LimitHit(kind: reading.kind, resets: reading.resets)
            emit(state.record)
        }
    }

    func continueAt(_ at: Date?) {
        state.withLock { state in
            guard at == nil || state.record.limitHit != nil else { return }
            state.record.continueAt = at
            emit(state.record)
        }
    }

    /// Once it's time and nothing's in the way (a half-typed line waits for its author), inside `state.withLock`. One that
    /// went on by itself (Claude Code can) has lost its `continueAt` by then, so it isn't told twice.
    func continueIfDue(_ state: inout State) {
        guard let at = state.record.continueAt, Date() >= at, !state.letGo, state.pendingPrompts.isEmpty,
            state.readyForText(submits: true)
        else { return }
        state.record.continueAt = nil
        state.trail.add("typed continue")
        type("continue", enter: true, paste: false, &state)
        emit(state.record)
    }

    /// Pauses before each "continue" after an API error that passes, here in the daemon too (`continueIfDue`).
    static let retryPauses: [TimeInterval] = [60, 300]

    /// An API error that passes (`Hooks.passes`) ended the turn: it goes on after a pause, twice in a row at most. Typing
    /// anything first, or the agent going on by itself, takes the `continueAt` away. Inside `state.withLock`.
    func retry(now: Date, _ state: inout State) {
        guard state.retries < Self.retryPauses.count else { return }
        let pause = Self.retryPauses[state.retries]
        state.retries += 1
        state.record.continueAt = now.addingTimeInterval(pause)
        state.trail.add("continues by itself in \(Int(pause)) s (\(state.retries) of \(Self.retryPauses.count))")
    }
}
