import Agents
import Core
import Foundation
import GitKit
import os

/// A running PTY plus its history ring buffer, disk log and status detector.
/// Everything that changes is in `state`, read and written only inside `state.withLock`; what it calls out to (the
/// daemon's callbacks, sends to clients) runs after the lock, or is queued under it where order matters (`emit`).
final class LiveSession: Sendable {
    static let ringLimit = 1 << 20
    /// How far back a menu is looked for (`menuScreen`): over an hour of a dot blinking.
    static let menuReach = 256 << 10
    /// Past this the log keeps only what the ring holds: a chatty dev server must not fill the disk.
    static let logLimit = 8 << 20

    /// What the daemon hears from it, fixed before the program starts.
    struct Callbacks: Sendable {
        /// Raw output, for the connections attached at that moment.
        var output: @Sendable (_ session: String, _ data: Data, _ attached: Set<Int>) -> Void = { _, _, _ in }
        /// A changed record, in the order the changes were made (`emit`).
        var status: @Sendable (LiveSession, Session) -> Void = { _, _ in }
        var firstPrompt: @Sendable (String) -> Void = { _ in }
        /// The topic the agent keeps in the terminal's title (Claude Code does): a short name for the session.
        var topic: (@Sendable (String) -> Void)?
        /// First local URL a process prints (dev servers): the app opens it in the worktree's browser.
        var localURL: (@Sendable (String) -> Void)?
        /// The port a server says it couldn't get, before it printed any URL.
        var busyPort: (@Sendable (Int) -> Void)?
        /// Plan usage the agent printed (Claude Code's "used 80% of your weekly limit").
        var limits: (@Sendable ([LimitScreens.Reading]) -> Void)?
        /// A turn began: how its folder was, to keep (`SessionTurns`).
        var turnStarted: (@Sendable (SessionTurns.Mark) -> Void)?
        /// A turn ended, started by this prompt: the pages its agent made keep a version (`Artifacts.keepVersions`).
        var turnEnded: (@Sendable (String) -> Void)?
    }

    let pty: PTY
    let callbacks: Callbacks
    /// Whether a pause can bring it back (its agent resumes, or it runs in tmux): fixed by what it was started with.
    let resumable: Bool
    let state: OSAllocatedUnfairLock<State>
    private let log: FileHandle?
    let logURL: URL
    let trail: StatusTrail
    /// Everything written into the program, in order: text Kelp types (Enter included, see `type`) and the user's keys,
    /// so keys pressed while a send waits for its Enter land after that Enter instead of being sent with it.
    let sends = DispatchQueue(label: "kelp.session.send")
    private let statusQueue = DispatchQueue(label: "kelp.session.status")
    let turnWork = DispatchQueue(label: "kelp.session.turn", qos: .utility)
    // "EADDRINUSE: address already in use :::3000", "Port 3000 is already in use", "… bind(2) for "127.0.0.1" port 3000".
    // swiftlint:disable:next force_try
    static let busyRegex = try! NSRegularExpression(
        pattern: #"port (\d{2,5}) is (?:already )?in use|(?:EADDRINUSE|address already in use)[^\n]*?[: ](\d{4,5})\b"#,
        options: .caseInsensitive)
    // swiftlint:disable:next force_try
    static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s\x1b'"]*"#)
    /// What an agent prints once its turn was cut short: Claude Code's "Interrupted · What should Claude do instead?" (and
    /// "User declined to answer questions" for Esc on its question, which ends the turn with no hook), Codex's
    /// "■ Conversation interrupted - tell the model what to do differently." Words placed one by one come with odd spacing.
    static let stoppedMarkers = [
        "Interrupted", "What should Claude do instead", "tell Claude what to do",
        "declined to answer questions", "Conversation interrupted", "tell the model what to do"
    ]
    static func printedStopped(_ seen: String) -> Bool {
        let flat = seen.replacing(/\s+/, with: " ")
        return stoppedMarkers.contains(where: flat.contains)
    }

    convenience init(
        record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16,
        rows: UInt16, callbacks: Callbacks
    ) throws {
        try Paths.ensure(historyDir)
        self.init(
            record: record, manifest: manifest,
            pty: try PTY(argv: argv, cwd: record.cwd, env: env, cols: cols, rows: rows),
            historyDir: historyDir, callbacks: callbacks)
    }

    /// `pty`: started for it, or taken over from the kelpd before this one (`Sessions.adopt`).
    init(record: Session, manifest: AgentManifest, pty: PTY, historyDir: URL, callbacks: Callbacks) {
        var rec = record
        // A woken session goes on in the same log: what it showed before the pause stays readable.
        logURL = historyDir.appendingPathComponent("\(record.id).log")
        trail = StatusTrail(history: historyDir, session: record.id)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        do { log = try FileHandle(forWritingTo: logURL) } catch {
            log = nil   // it runs, unrecorded
            Log.session.error("no history for session \(record.id, privacy: .public): \(error)")
        }
        var logSize = Int((try? log?.seekToEnd()) ?? 0)
        if logSize > Self.logLimit, let tail = Self.trimmed(log, logURL) { logSize = tail }
        self.pty = pty
        resumable = Sessions.resumable(record, [manifest])
        rec.pid = pty.pid
        self.callbacks = callbacks
        state = OSAllocatedUnfairLock(
            initialState: State(record: rec, manifest: manifest, logSize: logSize, callbacks: callbacks, trail: trail))
        pty.onOutput = { [weak self] d in self?.handleOutput(d) }
        pty.onExit = { [weak self] code in self?.handleExit(code) }
    }

    /// Output and status start flowing.
    func start() { pty.start() }

    /// Being deleted: it stops, and neither its exit nor anything else saves its record again.
    @discardableResult
    func discard() -> [pid_t] {
        state.withLock { $0.final = true }
        return pty.terminate()
    }
    /// Its record says its last (a pause, an end): nothing it does saves it again.
    func finish() { state.withLock { $0.final = true } }
    var isFinal: Bool { state.withLock { $0.final } }
    /// The program exited and that was handled (its record final, its log closed).
    var hasEnded: Bool { state.withLock { $0.ended } }
    var topic: String? { state.withLock { $0.lastTopic } }
    /// Claude Code transcript (from hook payloads): where its subagents' transcripts live.
    var transcriptPath: String? {
        get { state.withLock { $0.kept.transcript } }
        set { state.withLock { $0.kept.transcript = newValue } }
    }
    /// How long it has done nothing. An agent with hooks tells by its status (and someone typing): at rest it still redraws
    /// by itself, such as Claude Code's "Checking for updates". For the others, output is all there is.
    func idleSeconds(at now: Date) -> TimeInterval {
        state.withLock { st in
            let last =
                st.hooked
                ? max(st.record.statusAt ?? st.started, st.lastInputAt ?? st.started) : st.lastOutputAt ?? st.started
            return now.timeIntervalSince(last)
        }
    }
    var isAttached: Bool { state.withLock { !$0.attached.isEmpty } }
    /// The tree when its last turn started.
    var turnBase: String? { state.withLock { $0.turnTree } }
    /// Where the agent worked when its last turn started: `turnBase` is a snapshot of that folder.
    var turnDir: String? { state.withLock { $0.turnFolder } }
    var lastTurn: Turn? { state.withLock { $0.turnResult } }
    var snapshot: Session { state.withLock { $0.record } }

    /// The log's own last `ringLimit` bytes, read from the file, become the log: after a wake the ring holds only what was
    /// printed since, and trimming to that would drop most of what the session showed before its pause. Its new size.
    private static func trimmed(_ log: FileHandle?, _ url: URL) -> Int? {
        guard let log, let tail = Data(tail: ringLimit, of: url) else { return nil }
        let trimmed: Void? = Log.session.attempt("trimming \(url.lastPathComponent)") {
            try log.truncate(atOffset: 0)
            try log.write(contentsOf: tail)
        }
        guard trimmed != nil else { return nil }
        return tail.count
    }

    /// What a chunk of output asked for, done after the lock.
    private struct Heard: Sendable {
        var probe = false, topic: String?, url: String?, busy: Int?, limits: [LimitScreens.Reading] = []
        var answer: (input: String, asked: NSRegularExpression, after: Double)?
        var attached = Set<Int>(), id = ""
        var trimLog = false
    }

    /// On the PTY's queue, one chunk after another: the log is written here, after the lock, in that order.
    private func handleOutput(_ chunk: Data) {
        let text = state.withLock { st in
            let (whole, rest) = UTF8Chunks.split(st.utf8Carry + chunk)
            st.utf8Carry = rest
            return String(decoding: whole, as: UTF8.self)
        }
        let heard = state.withLock { hear(chunk, text, &$0) }
        // Disk, off the lock: a slow disk or the trim (a megabyte read back) doesn't hold up typing, attaching or status.
        try? log?.write(contentsOf: chunk)   // per chunk, unlogged: a full disk would flood the log (the trim says so)
        if heard.trimLog, let size = Self.trimmed(log, logURL) { state.withLock { $0.logSize = size } }
        if heard.probe { write(Data(ProgramStatus.queryReply.utf8)) }   // "I read OSC 7501": the agent starts reporting
        if heard.probe, heard.attached.isEmpty, text.contains(ProgramStatus.attributesQuery) {
            write(Data(ProgramStatus.attributesReply.utf8))   // an attached terminal answers it itself
        }
        if !heard.limits.isEmpty { callbacks.limits?(heard.limits) }
        if let url = heard.url { callbacks.localURL?(url) }
        if let port = heard.busy { callbacks.busyPort?(port) }
        if let topic = heard.topic { callbacks.topic?(topic) }
        if let answer = heard.answer {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.after) { [weak self] in
                self?.pressIfStillAsked(answer)
            }
        }
        callbacks.output(heard.id, chunk, heard.attached)
    }

    /// Inside the lock: the chunk into the ring and the readers, and what to do about it once the lock is let go.
    private func hear(_ chunk: Data, _ text: String, _ st: inout State) -> Heard {
        st.lastLifeUp = ProcessInfo.processInfo.systemUptime
        st.ring.append(chunk)
        // A copy, at twice the limit: removeFirst on Data only re-slices, and the storage kept every byte the session
        // ever printed (300 MB of output held 300 MB). The slack makes the copy rare.
        if st.ring.count > 2 * Self.ringLimit {
            st.ringModes.read(st.ring.dropLast(Self.ringLimit))
            st.ring = Data(st.ring.suffix(Self.ringLimit))
        }
        st.logSize += chunk.count
        let said = (st.record.summary, st.record.progress, st.record.limitHit)
        var heard = Heard(probe: st.readReports(text, chunk), topic: st.readTopic(text, chunk))
        // The chunk without escapes, once, for the two readers that want it.
        let plain = st.interruptArmed != nil || (!st.sawURL && st.wantsURL) ? StatusDetector.stripANSI(text) : ""
        if let arm = st.interruptArmed { st.interruptArmed = (arm.at, String((arm.seen + plain).suffix(4000))) }
        if Date() > st.redrawUntil {
            st.detector.output(text)
            st.lastOutputAt = Date()
        }
        st.notePasteMode(chunk)
        heard.answer = st.autoAnswer()
        heard.url = st.localURL(plain)
        heard.busy = st.busyPort(plain)
        heard.limits = st.newLimits(chunk)
        heard.attached = st.attached
        heard.id = st.record.id
        heard.trimLog = st.logSize > Self.logLimit
        emit(st.sync() ?? (said != (st.record.summary, st.record.progress, st.record.limitHit) ? st.record : nil))
        return heard
    }

    /// The auto-answer's key, once the question has had time to draw: only if it's still the one on screen and nobody
    /// typed meanwhile (the key would land in their text, or answer whatever came next).
    private func pressIfStillAsked(_ answer: (input: String, asked: NSRegularExpression, after: Double)) {
        let still = state.withLock { st -> Bool in
            guard !st.typedYet else { return false }
            let tail = st.screen(4000)
            return answer.asked.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
        }
        if still { write(Data(answer.input.utf8)) }
    }

    /// On the PTY's queue too, after its last output: the log closes after the last write.
    private func handleExit(_ code: Int32) {
        state.withLock { st in
            st.ended = true
            if st.record.status == .paused { return }
            st.detector.exited()
            let exitCode = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 0   // killed by a signal (closed, stopped) isn't a failure
            if exitCode != 0, st.record.agent != "shell" {
                st.record.summary = "Ended with an error (exit code \(exitCode))"
            }
            st.endCommands(at: Date())
            st.record.progress = nil
            st.record.exitCode = Int((code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f))
            emit(st.sync())
        }
        if let log { Log.session.attempt("closing a history log") { try log.close() } }
    }

    /// `kelp report`: the record to publish when only what it says changed (a new state goes out through `callbacks.status`).
    func report(_ report: ProgramStatus.Report) -> Session? {
        state.withLock { st in
            st.apply(report)
            let changed = st.sync()
            emit(changed)
            return changed == nil ? st.record : nil
        }
    }

    /// Hands a change to `callbacks.status` (saved, sent to the app, turn bookkeeping) in the order the changes were made:
    /// called inside `state.withLock`, so it's queued in that order and run one after another. Called after the lock,
    /// from whichever thread made the change, an older "working" could be saved after a newer "done" and stay.
    func emit(_ session: Session?) {
        guard let session else { return }
        statusQueue.async { self.callbacks.status(self, session) }   // holds the session until it ran: one just taken out of `live` still says so
    }
    /// `body` on the status queue, after every change queued before it.
    func inOrder(_ body: @escaping @Sendable () -> Void) { state.withLock { _ in statusQueue.async(execute: body) } }

    /// What time moves on: a quiet screen settling its status, text waiting to be typed, the timers. Whether there was
    /// anything to do: a session at rest (`State.atRest`) costs a look under its lock and no more.
    @discardableResult
    func tick() -> Bool {
        guard !state.withLock({ $0.atRest }) else { return false }
        steer()
        state.withLock { st in
            st.detector.tick()
            st.releaseStale()
            st.hooksSilent()
            if let arm = st.interruptArmed {
                if st.lastHookAt > arm.at {
                    st.interruptArmed = nil
                } else if Self.printedStopped(arm.seen) {
                    st.detector.interrupted()
                    st.nothingAsked()
                    st.record.summary = "Stopped by you"
                    st.interruptArmed = nil
                } else if Date().timeIntervalSince(arm.at) > 10 {
                    st.interruptArmed = nil
                }
            }
            if st.noteQuiet() { emit(st.record) }
            emit(st.sync())
            continueIfDue(&st)
            // Deliver the launch prompt once the TUI has drawn and gone quiet (or after a timeout).
            let quiet = Date().timeIntervalSince(st.lastOutputAt ?? st.started) > 1.5   // a program that prints nothing (cat) is quiet too
            let settled =
                (quiet && Date().timeIntervalSince(st.started) > 2) || Date().timeIntervalSince(st.started) > 25
            if settled { st.startedUp = true }
            // Not once it's let go: one being handed over takes what waits along (`handedOver`).
            if let prompt = st.pendingPrompts.first, settled, !st.letGo, st.readyForText(submits: !prompt.draft) {
                st.pendingPrompts.removeFirst()
                type(prompt.text, enter: !prompt.draft, paste: prompt.paste, &st)   // queued here, under the lock: nothing sent meanwhile gets ahead
            }
            if quiet, settled, !st.letGo, st.takesReport() {
                // To a program that takes no pastes on one line: its newlines would submit a part of it each.
                let report = st.reports.removeFirst()
                type(
                    st.kept.pasteMode ? report : report.replacingOccurrences(of: "\n", with: " "), enter: true,
                    paste: false,
                    &st)
            }
        }
        return true
    }

    /// Bytes into the program after anything Kelp is still typing (`sends`): a key never lands between a send's text and its Enter.
    func write(_ data: Data) { sends.async { [pty] in pty.write(data) } }

    /// For a hand-over: no input is taken from now on (a caller is refused, not told it went in), then waits until what
    /// was taken is written to the program (one that doesn't read gives up after `within` seconds).
    func drainInput(within seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        _ = letGo()
        while state.withLock({ $0.inputsInFlight }) > 0, Date() < end { usleep(10_000) }
        sends.sync {}
        while pty.queued.withLock({ $0 }) > 0, Date() < end { usleep(10_000) }
    }

    func update(_ change: @Sendable (inout Session) -> Void) -> Session {
        state.withLock {
            change(&$0.record)
            return $0.record
        }
    }

    /// Attached again to a program that kept running (a remote agent in its tmux session): StatusDetector.attachedToRunning.
    func attachedToRunning() { state.withLock { $0.detector.attachedToRunning() } }

    /// Hibernation: the PTY dies but the record says so, so the UI shows "Paused" instead of "Exited".
    func markHibernated() {
        state.withLock { st in
            st.trail.add("\(st.record.status.rawValue) → hibernated")
            st.detector.override(.paused)
            st.record.status = .paused
        }
    }

    func overrideStatus(_ status: AgentStatus) {
        state.withLock { st in
            st.detector.override(status)
            emit(st.sync())
        }
    }
}

extension LiveSession {
    var commands: [AgentCommand] { state.withLock { $0.commands } }
    /// `kelp why`: the status, where it came from, and when the agent last spoke up by itself.
    var statusWhy: String {
        state.withLock { st in
            let heard =
                st.lastHookAt == .distantPast ? "" : ", last heard \(Int(-st.lastHookAt.timeIntervalSinceNow)) s ago"
            return "\(st.detector.status.rawValue) (\(st.detector.source))\(heard)"
        }
    }
    var commandChanges: Int { state.withLock { $0.commandChanges } }
    /// The file its tools changed last, and how many edits so far.
    var lastEdit: (path: String?, count: Int) { state.withLock { ($0.lastEdit, $0.edits) } }
    func edited(_ path: String) {
        state.withLock {
            $0.lastEdit = path
            $0.edits += 1
        }
    }

    /// A hook's `cwd`: where the agent works now. The record when that changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let workDir = real(dir) == real(snapshot.cwd) ? nil : dir   // the folder it started in never changes
        return state.withLock { st in
            guard workDir != st.record.workDir else { return nil }
            st.record.workDir = workDir
            return st.record
        }
    }

    /// Whether that changed the record: one that didn't needs no save.
    func change(_ body: @Sendable (inout Session) -> Void) -> Bool {
        state.withLock { st in
            let before = st.record
            body(&st.record)
            return st.record != before
        }
    }
}
