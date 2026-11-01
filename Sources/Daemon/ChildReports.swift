import Foundation
import Core
import Agents
import os

/// What an agent's children have told it, and which sessions are only restarting.
final class ChildReports: Sendable {
    private struct State { var told: [String: AgentStatus] = [:], replies: [String: String] = [:], restarting: Set<String> = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A status from before this daemon was told before it, or will be found by asking.
    private let started = Date()

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
        return "<kelp from=\"\(name) \(s.id.prefix(8))\" status=\"\(s.status.rawValue)\">\n"
            + cut.replacingOccurrences(of: "</kelp", with: "<\\/kelp") + "\n</kelp>"
    }
}

extension Sessions {
    /// The parent of `create`, if it makes one: an agent's, and of an agent. A shell or a test run has no input to report to:
    /// typed there, a report would be run as a command. A command it runs is its own affair too.
    func parent(_ id: String?, of create: SessionCreate) throws -> String? {
        guard let id, create.command == nil, create.tmux == nil, !["shell", nil].contains(create.agent),
              let p = try store.session(id), !["shell", "custom"].contains(p.agent ?? "shell") else { return nil }
        return p.id
    }

    /// Every saved change of a session: its parent's news, and the end of its children. Never on the caller's queue, which is
    /// the session's own: these read the disk and take other sessions' locks.
    func familyHeard(_ s: Session) {
        guard !reports.isRestarting(s.id) else { return }
        let news = s.parent != nil && settings["agents.childReports"]?.bool != false && reports.isNews(s)
        guard news || s.status == .exited else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if news, let parent = s.parent { tell(parent, ChildReports.text(s, body: reportBody(s))) }
            if s.status == .exited { endChildren(of: s.id) }
        }
    }

    private func reportBody(_ s: Session) -> String {
        // What it printed, without the blank lines a redrawn screen leaves. Limit: an agent with no transcript to read (Codex
        // and the rest) reports this, spinner frames and all; its own log, once Kelp reads those, would be cleaner.
        func tail() -> String {
            let text = Log.session.attempt("reading what \(s.id) printed") { try printed(s.id, bytes: 1500) } ?? ""
            return text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.suffix(30).joined(separator: "\n")
        }
        switch s.status {
        case .done: return finalReply(s) ?? tail()
        case .exited: return "Exit code \(s.exitCode ?? 0)\n" + tail()
        default: return s.summary.isEmpty ? tail() : s.summary
        }
    }

    /// The reply that ended its turn. It's on disk a moment after the status says done (the Stop hooks run first), and until
    /// then the last one there is the turn's before. Off the caller's queue, so waiting here holds nobody.
    private func finalReply(_ s: Session) -> String? {
        var reply: String?
        for _ in 0..<8 {
            reply = existing(s.id).flatMap(agentUsage.transcript(of:)).flatMap(AgentUsage.lastReply(transcript:))
            if let reply, reports.isNewReply(reply, of: s.id) { return reply }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return reply   // the same words twice: they're this turn's as well
    }

    /// As its next prompt, when it can take one. A prompt someone is typing there comes first: tried again until it's sent.
    /// A parent that ended or paused hears nothing: `kelp session list` has it all when it's back.
    private func tell(_ parent: String, _ text: String, tries: Int = 120) {
        guard let p = existing(parent) else { return }
        do { try p.submit(text, enter: true) } catch {
            guard tries > 0 else { Log.session.error("a report for \(parent, privacy: .public) couldn't be sent: \(error)"); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.tell(parent, text, tries: tries - 1) }
        }
    }

    private func endChildren(of id: String) {
        Log.session.attempt("ending the children of \(id)") {
            for c in try store.sessions() where c.parent == id && c.status != .exited { _ = try SessionKill(id: c.id).handle(self) }
        }
    }

    /// A restart is a new session in the old one's place: its children stay its children.
    func passChildren(of old: String, to new: String) throws {
        for c in try store.sessions() where c.parent == old {
            if let ls = existing(c.id) { _ = ls.update { $0.parent = new }; publish(ls) } else { try change(c.id) { $0.parent = new } }
        }
    }
}
