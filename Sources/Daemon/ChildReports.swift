import Foundation
import Core
import Agents
import os

/// What an agent's children have told it, and which sessions are only restarting.
final class ChildReports: Sendable {
    private struct State {
        var told: [String: AgentStatus] = [:], replies: [String: String] = [:], said: [String: String] = [:], restarting: Set<String> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A status from before this daemon was told before it, or will be found by asking.
    private let started = Date()
    /// Where reports are made, one after another: a child's "needs you" can't reach its parent after the result that came
    /// next. Not the caller's queue, which is the session's own: these read the disk and take other sessions' locks.
    private let queue = DispatchQueue(label: "dev.kelp.child-reports", qos: .utility)
    /// Reports being made: a hand-over waits for them, as they're marked told already and the next kelpd wouldn't make them.
    private let making = DispatchGroup()

    func make(_ work: @escaping @Sendable () -> Void) {
        making.enter()
        queue.async { [making] in work(); making.leave() }
    }

    /// Before a hand-over: the reports on their way are kept (typed or owed) first, for up to `seconds`.
    func settle(within seconds: Double) { _ = making.wait(timeout: .now() + seconds) }

    /// An ended child's replies, kept only to tell its next one from the last (its status stays: an exit is said once).
    func ended(_ id: String) { state.withLock { $0.replies[id] = nil; $0.said[id] = nil } }
    /// A deleted one's everything.
    func forget(_ id: String) {
        state.withLock { $0.told[id] = nil; $0.replies[id] = nil }
        ended(id)
    }

    func restarting(_ id: String, _ on: Bool) { state.withLock { if on { $0.restarting.insert(id) } else { $0.restarting.remove(id) } } }
    func isRestarting(_ id: String) -> Bool { state.withLock { $0.restarting.contains(id) } }

    /// Once per stop: a session is saved for many reasons, and work begun again makes the next stop news. Leaving after a
    /// reported result says nothing new.
    func isNews(_ s: Session) -> Bool {
        state.withLock { st in
            if s.status == .working { st.told[s.id] = nil }
            guard [.done, .error, .waiting, .exited].contains(s.status), (s.statusAt ?? .distantPast) >= started,
                  st.told[s.id] != s.status, !(s.status == .exited && st.told[s.id] == .done) else { return false }
            st.told[s.id] = s.status
            return true
        }
    }

    /// What a Stop hook says the turn ended with, for the report that follows it.
    func said(_ reply: String, by id: String) { state.withLock { $0.said[id] = reply } }
    func takeSaid(by id: String) -> String? { state.withLock { $0.said.removeValue(forKey: id) } }

    /// Whether `reply` is one not reported yet, and now it is.
    func isNewReply(_ reply: String, of id: String) -> Bool {
        state.withLock { st in
            if st.replies[id] == reply { return false }
            st.replies[id] = reply
            return true
        }
    }

    /// What the parent reads. It's the child's text, so a closing tag in it can't end the block.
    static func text(_ s: Session, body: String, most: Int = 4000) -> String {
        let name = s.displayTitle.filter { !"\"<>\n".contains($0) }
        let cut = body.count > most ? "…" + body.suffix(most) + "\n(cut: kelp terminal read \(s.id.prefix(8)) shows more)" : body
        // As it will be typed: a control character taken out later would close the tag again.
        let safe = LiveSession.typeable(cut).replacingOccurrences(of: "<(/?kelp)", with: "<\\\\$1", options: [.regularExpression, .caseInsensitive])
        return "<kelp from=\"\(name) \(s.id.prefix(8))\" status=\"\(s.status.rawValue)\">\n" + safe + "\n</kelp>"
    }
}

extension Sessions {
    /// `id` and the sessions that started it, theirs in turn, nearest first (`parent`, else `startedBy`).
    func lineage(_ id: String) throws -> [Session] {
        var line: [Session] = [], next: String? = id
        while let n = next, line.count < 32, !line.contains(where: { $0.id == n }), let s = try store.session(n) {
            line.append(s)
            next = s.parent ?? s.startedBy
        }
        return line
    }

    /// The parent of `create`, if it makes one: an agent's, and of an agent. A shell or a test run has no input to report to:
    /// typed there, a report would be run as a command. A command it runs is its own affair too.
    func parent(_ id: String?, of create: SessionCreate) throws -> String? {
        guard let id, create.command == nil, create.tmux == nil, !["shell", nil].contains(create.agent),
              let p = try store.session(id), p.isAgent else { return nil }
        return p.id
    }

    /// The agent a command belongs to: `parent` on a command, which is no child (it hears nothing and outlives the agent).
    func starter(_ id: String?, of create: SessionCreate) throws -> String? {
        guard let id, create.command != nil, let p = try store.session(id), p.isAgent else { return nil }
        return p.id
    }

    /// Every saved change of a session: its parent's news, and the end of its children. Never on the caller's queue, which is
    /// the session's own: these read the disk and take other sessions' locks.
    func familyHeard(_ s: Session) {
        guard !reports.isRestarting(s.id) else { return }
        let news = s.parent != nil && settings["agents.childReports"]?.bool != false && reports.isNews(s)
        guard news || s.status == .exited else { return }
        reports.make { [weak self] in
            guard let self else { return }
            if news, let parent = s.parent, !askedEarlier(s), let body = reportBody(s) { tell(parent, ChildReports.text(s, body: body)) }
            if s.status == .exited { endChildren(of: s.id); reports.ended(s.id) }
        }
    }

    /// A question it has moved on from: what came next reports itself, and a "needs you" after it would be read as news.
    private func askedEarlier(_ s: Session) -> Bool {
        guard s.status == .waiting, let now = existing(s.id)?.snapshot else { return false }
        return (now.statusAt ?? .distantPast) > (s.statusAt ?? .distantPast) && now.status != .waiting
    }

    /// A report for `parent`. One that's paused, or between two kelpds, gets it when it runs again: it's been marked as told,
    /// and nothing would say it twice. One that ended has no one to read it.
    private func tell(_ parent: String, _ text: String) {
        if existing(parent)?.report(text) == true { return }
        Log.session.attempt("keeping a report for \(parent)") {
            guard let p = try store.session(parent), p.status != .exited else { return }
            try store.owe([OwedInput(session: parent, text: text, report: true)])
        }
    }

    /// nil: nothing to report after all.
    private func reportBody(_ s: Session) -> String? {
        // What it printed, without the blank lines a redrawn screen leaves. Limit: an agent whose replies Kelp can't read
        // reports this, spinner frames and all.
        func tail() -> String {
            let text = Log.session.attempt("reading what \(s.id) printed") { try printed(s.id, bytes: 1500) } ?? ""
            return text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.suffix(30).joined(separator: "\n")
        }
        switch s.status {
        case .done:
            if let said = reports.takeSaid(by: s.id) { return said.isEmpty ? tail() : said }
            let reply = finalReply(s)
            // It went on: a program that says "idle" for a second as a turn starts (Codex) hadn't stopped, and the real stop reports.
            return existing(s.id)?.snapshot.status == .working ? nil : reply ?? tail()
        case .exited: return "Exit code \(s.exitCode ?? 0)\n" + tail()
        default: return s.summary.isEmpty ? tail() : s.summary
        }
    }

    /// The reply that ended its turn, for an agent whose Stop doesn't say it. It's on disk a moment after the status says
    /// done, and until then the last one there is the turn's before. Off the caller's queue, so waiting here holds nobody.
    /// Limit: without a Stop that says it, a turn that spoke before its last tool call can report those words.
    private func finalReply(_ s: Session) -> String? {
        var reply: String?
        for _ in 0..<8 {
            reply = existing(s.id).flatMap(agentUsage.lastReply(of:))
            if let reply, reports.isNewReply(reply, of: s.id) { return reply }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return reply   // the same words twice: they're this turn's as well
    }

    /// Deleted, not ended (their workspace closed): no exit gets saved for them, so what one does happens here.
    func familyLeft(_ all: [Session]) {
        let ids = Set(all.map(\.id)), left = all.filter { $0.status != .exited && !reports.isRestarting($0.id) }
        for id in ids { reports.forget(id) }
        guard !left.isEmpty else { return }
        reports.make { [weak self] in
            guard let self else { return }
            for var s in left {
                endChildren(of: s.id)
                guard let parent = s.parent, !ids.contains(parent), settings["agents.childReports"]?.bool != false else { continue }
                s.status = .exited
                tell(parent, ChildReports.text(s, body: "Closed by the user"))
            }
        }
    }

    /// A restart that couldn't start the new one: it did end, and that went unheard while it was only restarting.
    func restartFailed(_ id: String) {
        reports.restarting(id, false)
        guard var s = Log.session.attempt("reading \(id)", { try store.session(id) }) ?? nil else { return }
        s.status = .exited   // its exit may be on its way to the record still
        familyHeard(s)
    }

    private func endChildren(of id: String) {
        Log.session.attempt("ending the children of \(id)") {
            for c in try store.sessions() where c.parent == id && c.status != .exited { _ = try SessionKill(id: c.id).handle(self) }
        }
    }

    /// A restart is a new session in the old one's place: its children stay its children, and what it hadn't typed is the
    /// new one's to type. `owed`: what was taken from the old one as it stopped.
    func passChildren(of old: String, to new: String, owed: [OwedInput]) throws {
        for c in try store.sessions() where c.parent == old {
            if let ls = existing(c.id) { _ = ls.update { $0.parent = new }; publish(ls) } else { try change(c.id) { $0.parent = new } }
        }
        existing(new)?.giveBack(owed + (existing(old)?.takeOwed() ?? []) + (try store.takeOwed(old)))
    }
}
