import Foundation
import os
import Core
import Agents
import GitKit

/// A running PTY plus its history ring buffer, disk log and status detector.
/// Everything that changes is in `state`, read and written only inside `state.withLock`; what it calls out to (the
/// daemon's callbacks, sends to clients) runs after the lock, or is queued under it where order matters (`emit`).
final class LiveSession: Sendable {
    static let ringLimit = 1 << 20
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
        /// Plan usage the agent printed (Claude Code's "used 80% of your weekly limit").
        var limits: (@Sendable ([ClaudeLimits.Reading]) -> Void)?
    }

    let pty: PTY
    let callbacks: Callbacks
    /// Whether a pause can bring it back (its agent resumes, or it runs in tmux): fixed by what it was started with.
    let resumable: Bool
    let state: OSAllocatedUnfairLock<State>
    private let log: FileHandle?
    private let logURL: URL
    /// Everything written into the program, in order: text Kelp types (Enter included, see `type`) and the user's keys,
    /// so keys pressed while a send waits for its Enter land after that Enter instead of being sent with it.
    let sends = DispatchQueue(label: "kelp.session.send")
    private let statusQueue = DispatchQueue(label: "kelp.session.status")
    private let turnWork = DispatchQueue(label: "kelp.session.turn", qos: .utility)
    // swiftlint:disable:next force_try
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s\x1b'"]*"#)
    /// What an agent prints once its turn was cut short: Claude Code's "Interrupted · What should Claude do instead?", Codex's
    /// "■ Conversation interrupted - tell the model what to do differently." Words placed one by one come with odd spacing.
    static let stoppedMarkers = ["Interrupted", "What should Claude do instead", "tell Claude what to do",
                                 "Conversation interrupted", "tell the model what to do"]
    static func printedStopped(_ seen: String) -> Bool {
        let flat = seen.replacing(/\s+/, with: " ")
        return stoppedMarkers.contains(where: flat.contains)
    }

    /// One turn of the agent: the tree when it started working, and what it changed by the time it stopped.
    struct Turn: Codable, Sendable {
        struct File: Codable, Sendable {
            var path: String, added: Int, removed: Int
        }
        var files: [File]; var seconds: Double
    }

    /// Esc or ⌃C, as one byte or as the kitty keyboard protocol sends them once the agent turns it on (Claude Code does):
    /// ESC[27u, ESC[99;5u — on a non-Latin layout the layout's own letter comes first (ESC[1089::99;5u).
    static func isStopKey(_ d: Data) -> Bool {
        d == Data([0x1B]) || d.contains(0x03) || String(decoding: d, as: UTF8.self).wholeMatch(of: /\x1B\[(27|([0-9]*:)*99;5)u/) != nil
    }

    /// Keys that pick an option in an agent's menu: Return, a digit, ⇧Tab (Claude Code's "allow all edits during this session").
    static func answersMenu(_ d: Data) -> Bool {
        let s = String(decoding: d, as: UTF8.self)
        if d.contains(0x0D) || (d.count == 1 && (0x31...0x39).contains(d[0])) || s == "\u{1B}[Z" { return true }
        return kittyKey(s).map { $0 == (13, 0) || $0 == (9, 1) } ?? false
    }

    /// A key pressed as the kitty keyboard protocol sends it (ESC[key:shifted:base;mods:event u): its key on the Latin
    /// layout (`base`, when a non-Latin one is on) and its modifiers (⇧ 1, ⌥ 2, ⌃ 4, lock keys left out). nil for a release.
    static func kittyKey(_ s: String) -> (key: Int, mods: Int)? {
        guard let m = s.wholeMatch(of: /\x1B\[([0-9]+)(?::[0-9]*)?(?::([0-9]+))?(?:;([0-9]+)(?::([0-9]+))?)?(?:;[0-9:]*)?u/),
              m.4.map({ $0 != "3" }) ?? true, let key = Int(m.2 ?? m.1) else { return nil }
        return (key, ((m.3.flatMap { Int($0) } ?? 1) - 1) & 0b111111)
    }

    convenience init(record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16,
                     rows: UInt16, callbacks: Callbacks) throws {
        try Paths.ensure(historyDir)
        self.init(record: record, manifest: manifest, pty: try PTY(argv: argv, cwd: record.cwd, env: env, cols: cols, rows: rows),
                  historyDir: historyDir, callbacks: callbacks)
    }

    /// `pty`: started for it, or taken over from the kelpd before this one (`Sessions.adopt`).
    init(record: Session, manifest: AgentManifest, pty: PTY, historyDir: URL, callbacks: Callbacks) {
        var rec = record
        // A woken session goes on in the same log: what it showed before the pause stays readable.
        logURL = historyDir.appendingPathComponent("\(record.id).log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
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
        state = OSAllocatedUnfairLock(initialState: State(record: rec, manifest: manifest, logSize: logSize, callbacks: callbacks))
        pty.onOutput = { [weak self] d in self?.handleOutput(d) }
        pty.onExit = { [weak self] code in self?.handleExit(code) }
    }

    /// Output and status start flowing.
    func start() { pty.start() }

    /// Being deleted: it stops, and neither its exit nor anything else saves its record again.
    @discardableResult
    func discard() -> [pid_t] { state.withLock { $0.final = true }; return pty.terminate() }
    /// Its record says its last (a pause, an end): nothing it does saves it again.
    func finish() { state.withLock { $0.final = true } }
    var isFinal: Bool { state.withLock { $0.final } }
    /// The program exited and that was handled (its record final, its log closed).
    var hasEnded: Bool { state.withLock { $0.ended } }
    var topic: String? { state.withLock { $0.lastTopic } }
    /// Claude Code transcript (from hook payloads): where its subagents' transcripts live.
    var transcriptPath: String? {
        get { state.withLock { $0.transcript } }
        set { state.withLock { $0.transcript = newValue } }
    }
    var idleSeconds: TimeInterval { state.withLock { Date().timeIntervalSince($0.lastOutputAt ?? $0.started) } }
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
        guard let log, let tail = Data(tailOf: url, bytes: ringLimit) else { return nil }
        let trimmed: Void? = Log.session.attempt("trimming \(url.lastPathComponent)") {
            try log.truncate(atOffset: 0)
            try log.write(contentsOf: tail)
        }
        guard trimmed != nil else { return nil }
        return tail.count
    }

    /// What a chunk of output asked for, done after the lock.
    private struct Heard: Sendable {
        var probe = false, topic: String?, url: String?, limits: [ClaudeLimits.Reading] = []
        var answer: (input: String, asked: NSRegularExpression, after: Double)?
        var attached = Set<Int>(), id = ""
        var trimLog = false
    }

    /// On the PTY's queue, one chunk after another: the log is written here, after the lock, in that order.
    private func handleOutput(_ d: Data) {
        let text = state.withLock { s in
            let (whole, rest) = UTF8Chunks.split(s.utf8Carry + d)
            s.utf8Carry = rest
            return String(decoding: whole, as: UTF8.self)
        }
        let heard = state.withLock { hear(d, text, &$0) }
        // Disk, off the lock: a slow disk or the trim (a megabyte read back) doesn't hold up typing, attaching or status.
        try? log?.write(contentsOf: d)   // per chunk, unlogged: a full disk would flood the log (the trim says so)
        if heard.trimLog, let n = Self.trimmed(log, logURL) { state.withLock { $0.logSize = n } }
        if heard.probe { write(Data(ProgramStatus.queryReply.utf8)) }   // "I read OSC 7501": the agent starts reporting
        if heard.probe, heard.attached.isEmpty, text.contains(ProgramStatus.attributesQuery) {
            write(Data(ProgramStatus.attributesReply.utf8))   // an attached terminal answers it itself
        }
        if !heard.limits.isEmpty { callbacks.limits?(heard.limits) }
        if let url = heard.url { callbacks.localURL?(url) }
        if let topic = heard.topic { callbacks.topic?(topic) }
        if let answer = heard.answer {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.after) { [weak self] in self?.pressIfStillAsked(answer) }
        }
        callbacks.output(heard.id, d, heard.attached)
    }

    /// Inside the lock: the chunk into the ring and the readers, and what to do about it once the lock is let go.
    private func hear(_ d: Data, _ text: String, _ s: inout State) -> Heard {
        s.lastLifeUp = ProcessInfo.processInfo.systemUptime
        s.ring.append(d)
        // A copy, at twice the limit: removeFirst on Data only re-slices, and the storage kept every byte the session
        // ever printed (300 MB of output held 300 MB). The slack makes the copy rare.
        if s.ring.count > 2 * Self.ringLimit { s.ringModes.read(s.ring.dropLast(Self.ringLimit)); s.ring = Data(s.ring.suffix(Self.ringLimit)) }
        s.logSize += d.count
        let said = (s.record.summary, s.record.progress)
        var h = Heard(probe: s.readReports(text, d), topic: s.readTopic(text, d))
        // The chunk without escapes, once, for the two readers that want it.
        let plain = s.interruptArmed != nil || (!s.sawURL && s.wantsURL) ? StatusDetector.stripANSI(text) : ""
        if let arm = s.interruptArmed { s.interruptArmed = (arm.at, String((arm.seen + plain).suffix(4000))) }
        if Date() > s.redrawUntil { s.detector.output(text); s.lastOutputAt = Date() }
        s.notePasteMode(d)
        h.answer = s.autoAnswer()
        h.url = s.localURL(plain)
        h.limits = s.newLimits(d)
        h.attached = s.attached
        h.id = s.record.id
        h.trimLog = s.logSize > Self.logLimit
        emit(s.sync() ?? (said != (s.record.summary, s.record.progress) ? s.record : nil))
        return h
    }

    /// The auto-answer's key, once the question has had time to draw: only if it's still the one on screen and nobody
    /// typed meanwhile (the key would land in their text, or answer whatever came next).
    private func pressIfStillAsked(_ a: (input: String, asked: NSRegularExpression, after: Double)) {
        let still = state.withLock { s -> Bool in
            guard !s.typedYet else { return false }
            let tail = s.screen(4000)
            return a.asked.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
        }
        if still { write(Data(a.input.utf8)) }
    }

    /// On the PTY's queue too, after its last output: the log closes after the last write.
    private func handleExit(_ code: Int32) {
        state.withLock { s in
            s.ended = true
            if s.record.status == .hibernated { return }
            s.detector.exited()
            let exitCode = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 0   // killed by a signal (closed, stopped) isn't a failure
            if exitCode != 0, s.record.agent != "shell" { s.record.summary = "Ended with an error (exit code \(exitCode))" }
            s.endCommands(at: Date())
            s.record.progress = nil; s.record.exitCode = Int((code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f))
            emit(s.sync())
        }
        if let log { Log.session.attempt("closing a history log") { try log.close() } }
    }

    /// `kelp report`: the record to publish when only what it says changed (a new state goes out through `callbacks.status`).
    func report(_ r: ProgramStatus.Report) -> Session? { report { _ in r } }

    /// The report made from the status it lands on, under the same lock.
    func report(_ make: @Sendable (AgentStatus) -> ProgramStatus.Report) -> Session? {
        state.withLock { s in
            s.apply(make(s.record.status))
            let changed = s.sync()
            emit(changed)
            return changed == nil ? s.record : nil
        }
    }

    /// Hands a change to `callbacks.status` (saved, sent to the app, turn bookkeeping) in the order the changes were made:
    /// called inside `state.withLock`, so it's queued in that order and run one after another. Called after the lock,
    /// from whichever thread made the change, an older "working" could be saved after a newer "done" and stay.
    private func emit(_ s: Session?) {
        guard let s else { return }
        statusQueue.async { self.callbacks.status(self, s) }   // holds the session until it ran: one just taken out of `live` still says so
    }
    /// `body` on the status queue, after every change queued before it.
    func inOrder(_ body: @escaping @Sendable () -> Void) { state.withLock { _ in statusQueue.async(execute: body) } }

    /// Called with every status change: a snapshot when work starts, the changes when it stops (git work off the lock).
    func noteTurn(_ status: AgentStatus, remotes: Remotes = .none) {
        let (shell, starting, ending, start, cwd) = state.withLock { s in
            // A shell or a plain command (a dev server, a script) has no turns: its output comes and goes, and each change
            // would copy the index and hash the tree again.
            let shell = s.record.agent == "shell" || s.record.agent == "custom"
            let starting = status == .working && !s.inTurn, ending = s.inTurn && status != .working
            if starting {
                s.inTurn = true
                s.turnStart = Date()
                s.turnFolder = s.record.currentDir
            }
            if ending { s.inTurn = false }
            return (shell, starting, ending, s.turnStart, s.turnFolder ?? s.record.cwd)
        }
        guard !shell, starting || ending else { return }
        // One after another, per session: a short turn's end waits for its own start snapshot instead of diffing against
        // the previous turn's (which credited it with that turn's changes), and snapshots can't land out of order.
        turnWork.async { [weak self] in
            if starting {
                let tree = try? Git.snapshotTree(cwd, remotes: remotes)
                self?.state.withLock { $0.turnTree = tree }
            } else if let start, let base = self?.turnBase {
                let files = ((try? Git.changesSince(tree: base, cwd: cwd, remotes: remotes)) ?? [])
                    .map { Turn.File(path: $0.path, added: $0.added, removed: $0.removed) }
                self?.state.withLock { $0.turnResult = Turn(files: files, seconds: Date().timeIntervalSince(start)) }
            }
        }
    }

    func tick() {
        steer()
        state.withLock { s in
            s.detector.tick()
            s.releaseStale()
            if let arm = s.interruptArmed {
                if s.lastHookAt > arm.at { s.interruptArmed = nil }
                else if Self.printedStopped(arm.seen) {
                    s.detector.interrupted()
                    s.record.summary = "Stopped by you"
                    s.interruptArmed = nil
                } else if Date().timeIntervalSince(arm.at) > 10 { s.interruptArmed = nil }
            }
            emit(s.sync())
            // Deliver the launch prompt once the TUI has drawn and gone quiet (or after a timeout).
            let quiet = Date().timeIntervalSince(s.lastOutputAt ?? s.started) > 1.5   // a program that prints nothing (cat) is quiet too
            let settled = (quiet && Date().timeIntervalSince(s.started) > 2) || Date().timeIntervalSince(s.started) > 25
            if settled { s.startedUp = true }
            // Not once it's let go: one being handed over takes what waits along (`handedOver`).
            if let p = s.pendingPrompts.first, settled, !s.letGo, s.readyForText(submits: !p.draft) {
                s.pendingPrompts.removeFirst()
                type(p.text, enter: !p.draft, paste: p.paste, &s)   // queued here, under the lock: nothing sent meanwhile gets ahead
            }
        }
    }

    /// Bytes into the program after anything Kelp is still typing (`sends`): a key never lands between a send's text and its Enter.
    func write(_ d: Data) { sends.async { [pty] in pty.write(d) } }

    /// For a hand-over: no input is taken from now on (a caller is refused, not told it went in), then waits until what
    /// was taken is written to the program (one that doesn't read gives up after `within` seconds).
    func drainInput(within seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        _ = letGo()
        while state.withLock({ $0.inputsInFlight }) > 0, Date() < end { usleep(10_000) }
        sends.sync {}
        while pty.queued.withLock({ $0 }) > 0, Date() < end { usleep(10_000) }
    }

    /// Keystrokes from a UI: the first submitted line becomes the source of the tab title.
    func userInput(_ d: Data) {
        guard !state.withLock({ $0.letGo }) else { return }   // its program stopping or handed over: an attach's keys go nowhere
        write(d)
        guard !TerminalReplies.isReply(d) else { return }   // the terminal answering the agent, not the user typing
        let firstPrompt = state.withLock { s -> String? in
            // Keys that answer a question or menu on screen ("1", Return on an option) aren't a line being written.
            let answering = s.trustQuestionOpen() || s.menuOpen() || (s.record.status == .waiting && d.count == 1 && (0x31...0x39).contains(d[0]))
            s.typedYet = true
            s.dialogSettled = true
            s.draftWaiting = false
            s.detector.input(typing: !d.contains(0x0D))   // keys without Return: the prompt is still being written
            var read: Session?
            if s.record.unread { s.record.unread = false; read = s.record }   // typing into it is having read it
            // Hooks send nothing for a cut-short turn, and a heuristic would call it done a few seconds late: the screen decides.
            if Self.isStopKey(d), s.record.status == .working || (s.hooked && s.record.status == .waiting) { s.interruptArmed = (Date(), "") }
            if s.hooked {
                // An answer to a question or a permission menu: it works again (Claude Code sends no hook for that).
                if s.record.status == .waiting, Self.answersMenu(d) {
                    s.detector.override(.working); s.interruptArmed = (Date(), "")
                }
            }
            emit(s.sync() ?? read)
            if answering { s.typing = ""; return nil }
            return s.noteTyping(d)
        }
        if let line = firstPrompt { let cb = callbacks.firstPrompt; DispatchQueue.global().async { cb(line) } }
    }

    func update(_ f: @Sendable (inout Session) -> Void) -> Session { state.withLock { f(&$0.record); return $0.record } }

    /// Attached again to a program that kept running (a remote agent in its tmux session): StatusDetector.attachedToRunning.
    func attachedToRunning() { state.withLock { $0.detector.attachedToRunning() } }

    /// Hibernation: the PTY dies but the record says so, so the UI shows "Paused" instead of "Exited".
    func markHibernated() { state.withLock { s in s.detector.override(.hibernated); s.record.status = .hibernated } }

    func overrideStatus(_ status: AgentStatus) { state.withLock { s in s.detector.override(status); emit(s.sync()) } }

    /// `State.hook`: the record goes out when its status or what the row says changed.
    func hook(_ event: String, trigger: String? = nil, message: String? = nil) {
        state.withLock { s in
            let said = s.record.summary, awaited = s.record.awaiting
            s.hook(event, trigger: trigger, message: message)
            emit(s.sync() ?? (s.record.summary != said || s.record.awaiting != awaited ? s.record : nil))
        }
    }

    /// Stop: done, or still working while it goes on by itself (TurnEnd); the record says what it works toward and
    /// what runs in the background. Returns the verdict and the hook's time, which `release` checks.
    func stop(_ tasks: [JSONValue], goal: GoalStatus?) -> (TurnEnd.Verdict, Date) {
        state.withLock { s in
            let now = Date()
            s.heard(at: now)
            let (verdict, running) = s.turnEnd.stop(tasks, goal: goal)
            s.endCommands(at: now)
            s.holding = verdict != .done
            s.record.background = running.isEmpty ? nil : running
            if case .command(let c) = verdict { s.record.awaiting = c } else { s.record.awaiting = nil }
            if case .goal(let c) = verdict { s.record.goal = c } else if goal?.met != false { s.record.goal = nil }
            s.detector.hook(verdict == .done ? "done" : "working")
            emit(s.sync() ?? s.record)
            return (verdict, now)
        }
    }

    static let commandLimit = 100

    /// A command its shell tool started or ended (`kelp hook command`), into its list; the row says the one running. The
    /// record when what it runs changed.
    func ran(_ c: AgentCommand) -> Session? {
        state.withLock { s in
            // A sign of life, not a hook that says what the turn does: an Esc that stopped this command is still read off the screen.
            s.lastLifeUp = ProcessInfo.processInfo.systemUptime
            if let i = s.commands.lastIndex(where: { $0.id == c.id }) {
                let started = s.commands[i].started   // the end keeps the start it was told of
                s.commands[i] = c
                s.commands[i].started = min(started, c.started)
            } else {
                s.commands.append(c)
                if s.commands.count > Self.commandLimit { s.commands.removeFirst(s.commands.count - Self.commandLimit) }
            }
            _ = s.newCommands()
            let moved = c.outcome == .background && s.sentToBackground(c.command)
            let shown = s.showRunning()
            return moved || shown ? s.record : nil
        }
    }

    var commands: [AgentCommand] { state.withLock { $0.commands } }
    var commandChanges: Int { state.withLock { $0.commandChanges } }

    /// A Stop held as working that nothing came after (`at`: its time): the goal was met, or the wait ran out.
    func release(_ at: Date) {
        state.withLock { s in
            guard s.lastHookAt == at, s.detector.status == .working else { return }
            s.holding = false
            s.record.goal = nil
            s.record.awaiting = nil
            s.detector.hook("done")
            emit(s.sync())
        }
    }

    /// A hook's `cwd`: where the agent works now. The record when that changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        let w = real(dir) == real(snapshot.cwd) ? nil : dir   // the folder it started in never changes
        return state.withLock { s in
            guard w != s.record.workDir else { return nil }
            s.record.workDir = w; return s.record
        }
    }

    /// The record when that changed it.
    func setUnread(_ unread: Bool) -> Session? {
        state.withLock { s in
            guard s.record.unread != unread else { return nil }
            s.record.unread = unread; return s.record
        }
    }

    func tail(_ n: Int) -> Data { state.withLock { $0.ring.suffix(min(max(0, n), Self.ringLimit)) } }
    /// The history, `conn` gets the output from here on. `send` runs under the lock with that history, so it goes out
    /// before any of the live output that follows. It starts by setting the modes the cut-off part had set (Codex's
    /// alternate screen and mouse reporting): without them the new terminal keeps the wheel and clicks to itself.
    /// nil once it was let go (`letGo`): its program is stopping, and nothing it shows would be live.
    @discardableResult
    func attach(_ conn: Int, send: @Sendable (Data) -> Void = { _ in }) -> Data? {
        state.withLock { s in
            guard !s.letGo else { return nil }
            s.attached.insert(conn)
            let history = s.historyModes.restore + TerminalReplies.withoutQueries(s.ring.suffix(Self.ringLimit))
            send(history)
            return history
        }
    }
    func detach(_ conn: Int) { state.withLock { _ = $0.attached.remove(conn) } }
    /// Out of `live` with its program still to stop (paused, deleted): nobody attaches from now on. Who was attached.
    func letGo() -> Set<Int> {
        state.withLock { s in
            s.letGo = true
            defer { s.attached = [] }
            return s.attached
        }
    }

    /// Input from a client, `work` writing it: nil (nothing done) once the session was let go, its program stopping, so
    /// the caller wakes it again instead. An idle pause doesn't let go of one with input on its way (`letGoIdle`).
    func input<T>(_ work: () throws -> T) rethrows -> T? {
        let open = state.withLock { s -> Bool in
            guard !s.letGo else { return false }
            s.inputs += 1
            s.inputsInFlight += 1
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
    /// `letGo` for an idle pause: only while nobody is attached and no input came since there were `seen`.
    func letGoIdle(seen: Int) -> Bool {
        state.withLock { s in
            guard s.attached.isEmpty, s.inputs == seen, s.inputsInFlight == 0 else { return false }
            s.letGo = true; return true
        }
    }

    /// Given up to the kelpd that takes over (`Sessions.handOver`), its output no longer read here: what that one needs to
    /// show the same history. The log holds every byte the ring does by now (it's written as output is handled).
    func handedOver(fd: Int32) -> Handover.Session {
        state.withLock { s in
            Handover.Session(id: s.record.id, pid: pty.pid, fd: fd, modes: String(decoding: s.historyModes.restore, as: UTF8.self),
                             bytes: min(s.ring.count, Self.ringLimit), pending: s.pendingPrompts.map { .init(text: $0.text, draft: $0.draft, paste: $0.paste) })
        }
    }

    /// Taken over from the kelpd this one replaced: its history is the log's last `bytes` (that one's ring), in `modes`. It's
    /// long past starting up: no launch prompt, startup answer or title from its first prompt comes now.
    /// What was waiting to be typed (`pending`) is typed here once the agent is ready, as it would have been there.
    func adopted(modes: String, bytes: Int, pending: [Handover.Prompt] = []) {
        let history = bytes > 0 ? Data(tailOf: logURL, bytes: bytes) ?? Data() : Data()
        state.withLock { s in
            s.pendingPrompts = pending.map { ($0.text, $0.draft, $0.paste) }
            s.ring = history; s.ringModes.read(Data(modes.utf8))
            s.detector.adopted(s.record.status, screen: String(decoding: history.suffix(64_000), as: UTF8.self))
            // A question read again and found to be none: the turn ended long ago, so one already read stays read.
            if s.detector.status != s.record.status {
                s.record.status = s.detector.status
                emit(s.record)
            }
            s.startedUp = true
            s.typedYet = true
            s.dialogSettled = true
            s.sawFirstPrompt = true
        }
    }
}
