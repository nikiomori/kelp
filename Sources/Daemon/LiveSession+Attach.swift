import Agents
import Core
import Foundation

// Who watches a session: its history for a terminal attached, letting go, and the hand-over between kelpds.

extension LiveSession {
    func tail(_ count: Int) -> Data { state.withLock { $0.ring.suffix(min(max(0, count), Self.ringLimit)) } }
    /// The history, `conn` gets the output from here on. `send` runs under the lock with that history, so it goes out
    /// before any of the live output that follows. It starts by setting the modes the cut-off part had set (Codex's
    /// alternate screen and mouse reporting): without them the new terminal keeps the wheel and clicks to itself.
    /// nil once it was let go (`letGo`): its program is stopping, and nothing it shows would be live.
    @discardableResult
    func attach(_ conn: Int, send: @Sendable (Data) -> Void = { _ in }) -> Data? {
        state.withLock { st in
            guard !st.letGo else { return nil }
            st.attached.insert(conn)
            let history = st.historyModes.restore + TerminalReplies.withoutQueries(st.ring.suffix(Self.ringLimit))
            send(history)
            return history
        }
    }
    func detach(_ conn: Int) { state.withLock { _ = $0.attached.remove(conn) } }
    /// Out of `live` with its program still to stop (paused, deleted): nobody attaches from now on. Who was attached.
    func letGo() -> Set<Int> {
        state.withLock { st in
            st.letGo = true
            defer { st.attached = [] }
            return st.attached
        }
    }

    /// Input from a client, `work` writing it: nil (nothing done) once the session was let go, its program stopping, so
    /// the caller wakes it again instead. An idle pause doesn't let go of one with input on its way (`letGoIdle`).
    func input<T>(_ work: () throws -> T) rethrows -> T? {
        let open = state.withLock { st -> Bool in
            guard !st.letGo else { return false }
            st.inputs += 1
            st.inputsInFlight += 1
            return true
        }
        guard open else { return nil }
        defer { state.withLock { $0.inputsInFlight -= 1 } }
        return try work()
    }
    /// Drawn and quiet after its start (or 25 s on): text sent now is typed at once, not kept for later.
    var startedUp: Bool { state.withLock { $0.startedUp } }
    /// Inputs taken so far: an idle pause lets go only if none came after it looked.
    var inputs: Int { state.withLock { $0.inputs } }
    /// `letGo` for an idle pause: only while nobody is attached, no input came since there were `seen`, and it still rests.
    /// Candidates go one after another, up to 3 s each, so a later one may have moved on since it was picked.
    func letGoIdle(seen: Int) -> Bool {
        state.withLock { st in
            guard st.attached.isEmpty, st.inputs == seen, st.inputsInFlight == 0,
                [.done, .idle].contains(st.record.status)
            else { return false }
            guard st.typing.isEmpty, !st.draftWaiting else { return false }   // a half-typed line or a draft would go with the program
            st.letGo = true
            return true
        }
    }

    /// Given up to the kelpd that takes over (`Sessions.handOver`), its output no longer read here: what that one needs to
    /// show the same history. The log holds every byte the ring does by now (it's written as output is handled).
    func handedOver(fd: Int32) -> Handover.Session {
        state.withLock { st in
            Handover.Session(
                id: st.record.id, pid: pty.pid, fd: fd, modes: String(decoding: st.historyModes.restore, as: UTF8.self),
                bytes: min(st.ring.count, Self.ringLimit),
                pending: st.pendingPrompts.map { .init(text: $0.text, draft: $0.draft, paste: $0.paste) },
                status: .init(
                    holding: st.holding, parked: st.parked, hooked: st.detector.hooked, asking: st.asking,
                    questionOpen: st.questionOpen, turnEnd: st.turnEnd, transcript: st.transcript,
                    boxEmpty: st.boxEmpty,
                    pasteMode: st.pasteMode, draftWaiting: st.draftWaiting, typing: st.typing, hooksSpoke: st.hooksSpoke
                ),
                reports: st.reports)
        }
    }

    /// Taken over from the kelpd this one replaced: its history is the log's last `bytes` (that one's ring), in `modes`. It's
    /// long past starting up: no launch prompt, startup answer or title from its first prompt comes now.
    /// What was waiting to be typed (`pending`) is typed here once the agent is ready, as it would have been there.
    /// `status`: what its status rested on there; nil from a kelpd that didn't say.
    func adopted(
        modes: String, bytes: Int, pending: [Handover.Prompt] = [], reports: [String] = [],
        status: Handover.Status? = nil
    ) {
        let history = bytes > 0 ? Data(tail: bytes, of: logURL) ?? Data() : Data()
        state.withLock { st in
            st.pendingPrompts = pending.map { ($0.text, $0.draft, $0.paste) }
            st.reports = reports
            st.ring = history
            st.ringModes.read(Data(modes.utf8))
            if let status {
                st.holding = status.holding
                st.parked = status.parked
                st.asking = status.asking
                st.questionOpen = status.questionOpen
                st.turnEnd = status.turnEnd
                st.transcript = status.transcript
                st.boxEmpty = status.boxEmpty ?? false
                st.draftWaiting = status.draftWaiting ?? false
                st.typing = status.typing ?? ""
                st.hooksSpoke = status.hooksSpoke ?? false
            }
            st.pasteMode = status?.pasteMode ?? modes.contains("\u{1B}[?2004h")   // from a kelpd that didn't say: as near as its modes tell
            st.detector.adopted(
                st.record.status, screen: String(decoding: history.suffix(64_000), as: UTF8.self),
                hooked: status?.hooked
            )
            st.trail.add("\(st.record.status.rawValue) → \(st.detector.status.rawValue)  \(st.detector.source)")
            // A question read again and found to be none: the turn ended long ago, so one already read stays read.
            if st.detector.status != st.record.status {
                st.record.status = st.detector.status
                emit(st.record)
            }
            st.startedUp = true
            st.typedYet = true
            st.dialogSettled = true
            st.sawFirstPrompt = true
        }
    }
}
