import Agents
import Core
import Foundation

// What a session's output says: its reports, title, paste mode, URLs, a busy port, plan limits, an auto answer.

extension LiveSession.State {
    // What a chunk of output says. Whether a chunk has a sequence at all is asked of its bytes: String.contains
    // compares Characters, and on a stream of output that was most of the daemon's time.

    /// OSC 7501 reports (true: the agent asked whether Kelp reads them) and ConEmu progress. An agent with hooks is read
    /// for its subagents alone: only there does it say what each does. Its status stays its hooks'.
    mutating func readReports(_ text: String, _ data: Data) -> Bool {
        var probe = false
        if data.range(of: Data(ProgramStatus.prefix.utf8)) != nil || !oscCarry.isEmpty {
            for item in ProgramStatus.scan(text, carry: &oscCarry) {
                switch item {
                case .query: probe = true
                case .report(let report) where report.id != nil: subagentReported(report)
                case .report(let report) where !hooked: apply(report)
                default: break
                }
            }
        }
        if data.range(of: Data(ProgramStatus.conEmuPrefix.utf8)) != nil,
            let progress = ProgramStatus.conEmuProgress(text).last
        {
            record.progress = progress
        }
        return probe
    }

    /// A hook knows a subagent's kind and may come first, so a report adds no more than it knows.
    private mutating func subagentReported(_ report: ProgramStatus.Report) {
        guard let id = report.id else { return }
        var running = record.subagents ?? [:], tasks = record.subagentTasks ?? [:]
        if report.state == "working" || report.state == "blocked" {
            if running[id] == nil { running[id] = "" }
            if let title = report.title { tasks[id] = title }
        } else {
            running[id] = nil
            tasks[id] = nil
        }
        record.subagents = running.isEmpty ? nil : running
        record.subagentTasks = tasks.isEmpty ? nil : tasks
    }

    /// A new topic from the terminal title the agent sets.
    mutating func readTopic(_ text: String, _ data: Data) -> String? {
        guard wantsTopic, data.range(of: Data("\u{1B}]".utf8)) != nil || !titleCarry.isEmpty,
            let topic = TerminalTitle.scan(text, carry: &titleCarry).last.flatMap({
                TerminalTitle.topic($0, names: selfNames)
            }), topic != lastTopic
        else {
            return nil
        }
        lastTopic = topic
        return topic
    }

    /// Bracketed paste switched on or off (the sequence can be split across two reads).
    mutating func notePasteMode(_ data: Data) {
        let scan = pasteCarry + data
        if let on = scan.range(of: Data("\u{1B}[?2004".utf8), options: .backwards), on.upperBound < scan.endIndex {
            kept.pasteMode = scan[on.upperBound] == UInt8(ascii: "h")
        }
        pasteCarry = Data(data.suffix(7))
    }

    /// The keys that answer a question the manifest knows (a menu is steered instead, see `steer`).
    mutating func autoAnswer() -> (input: String, asked: NSRegularExpression, after: Double)? {
        guard !autoAnswers.isEmpty, !typedYet, Date().timeIntervalSince(started) < 90 else { return nil }
        let tail = screen(4000)
        let whole = NSRange(tail.startIndex..., in: tail)
        guard let index = autoAnswers.firstIndex(where: { $0.0.firstMatch(in: tail, range: whole) != nil }) else {
            return nil
        }
        let answer = autoAnswers[index].1
        if let choose = answer.choose,
            let re = Log.session.attempt(
                "an auto-answer's choice pattern", { try NSRegularExpression(pattern: choose) })
        {
            steering = (re, Date(), .distantPast, autoAnswers[index].0)
            autoAnswers.remove(at: index)   // closed loop, see steer()
            return nil
        }
        let asked = autoAnswers.remove(at: index).0
        dialogSettled = true
        return (answer.input, asked, answer.after ?? 0.4)
    }

    /// The first local URL it prints (a dev server), with 0.0.0.0 and [::] as localhost.
    mutating func localURL(_ plain: String) -> String? {
        guard !sawURL, wantsURL,
            let match = LiveSession.urlRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
            let range = Range(match.range, in: plain)
        else { return nil }
        sawURL = true
        return String(plain[range]).replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(
            of: "[::]", with: "localhost")
    }

    /// The port a server couldn't get, once: a run that printed its page got one.
    mutating func busyPort(_ plain: String) -> Int? {
        guard !sawURL, !sawBusy, wantsURL else { return nil }
        guard
            let match = LiveSession.busyRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain))
        else { return nil }
        let range = [1, 2].lazy.compactMap { Range(match.range(at: $0), in: plain) }.first
        sawBusy = true
        return range.flatMap { Int(plain[$0]) }
    }

    /// Plan limits its agent printed (`limitScreen`: Claude Code's usage, or Cursor Agent's or Codex's once it ran out),
    /// when they changed.
    mutating func newLimits(_ data: Data) -> [LimitScreens.Reading] {
        guard let limitScreen, data.range(of: Data("limit".utf8)) != nil else { return [] }
        let found = LimitScreens.read(limitScreen, screen(1200))
        if !hooked, let hit = found.first(where: { $0.percent >= 100 }) {
            limitSeen = (LimitHit(kind: hit.kind, resets: hit.resets), Date())
            settleLimit()
        }
        guard !found.isEmpty, found != lastLimits else { return [] }
        lastLimits = found
        return found
    }

    /// The words count only by a turn that stopped: the same ones in a file it reads, or a test's output, stop nothing.
    /// Hooks say so themselves (`hitLimit`). Limit: words printed in the last half minute of a turn that ended for another
    /// reason count too.
    mutating func settleLimit() {
        guard let seen = limitSeen, [.done, .error].contains(record.status), let at = record.statusAt,
            abs(seen.at.timeIntervalSince(at)) < 30
        else { return }
        record.limitHit = seen.hit
        limitSeen = nil
    }
}
