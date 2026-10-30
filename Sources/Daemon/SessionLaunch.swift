import Foundation
import GRDB
import Core
import GitKit
import Agents
import AgentData

/// What goes into starting, pausing and waking a session: its environment and account, the trust answer, resuming its
/// conversation, titles, and the agent manifests.
extension Sessions {

    /// One sentence naming the skills that are turned on (their folders exist).
    static func kelpContext(_ dir: URL) -> String? {
        let on = ["kelp-extensions", "kelp-settings"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !on.isEmpty else { return nil }
        return "This Claude Code session runs inside Kelp, a macOS IDE; the user sees Kelp's window, not Claude Code's UI. Any request to add "
            + "or change a panel, tab, list, command, setting or theme means Kelp: follow the \(on.joined(separator: " / ")) skill. "
            + "Never create Claude Code mods, plugins, hooks or MCP servers for such requests — Kelp doesn't load them."
    }

    static func hasPlugins(_ dir: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains(where: \.hasDirectoryPath)
    }

    /// One place for a session's environment, used to start it and to wake it: the account profile it was started with
    /// comes back with it (it used to be dropped on wake and restart, so the session returned on the default login).
    func launchEnv(_ m: AgentManifest, _ rec: Session) -> [String: String] {
        var env = m.resolvedEnv
        if let name = rec.profile, let prof = profile(name, agent: m.id) { env[prof.key] = prof.dir }
        // Not into tmux: its server keeps the first client's environment for every pane, whichever tab they're shown in.
        if Tmux.session(rec.argv) == nil { env["KELP_SESSION"] = rec.id }
        env["KELP_SOCKET"] = socketPath; env["KELP_HOME"] = root.path
        // Written at each start and wake, so a session woken after an update gets this kelpd's hooks.
        if remotes.of(rec.cwd) == nil, let t = m.hooks { wire(t, m, rec, &env) }
        env["PATH"] = Self.childPath
        return env
    }

    /// Kelp's plugin dir for an agent; its hooks file is this with ".json".
    func hooksDir(_ m: AgentManifest) -> URL { root.appendingPathComponent("hooks-\(m.id)") }

    /// What `t` needs in the environment. A variable the user set themselves stays theirs, and the hooks aren't wired
    /// (`wiredHooks`); `.settingsFlag` is on the command line (`spawn`).
    private func wire(_ t: HookTransport, _ m: AgentManifest, _ rec: Session, _ env: inout [String: String]) {
        let dir = hooksDir(m), file = dir.appendingPathExtension("json")
        if let key = t.env, env[key] != nil { return }
        do {
            switch t {
            case .settingsFlag: break
            case .pluginDir(let key): try Hooks.writePlugin(dir: dir); env[key] = dir.path
            case .settingsFile(let key, let base):
                try base.map { try Hooks.writeSettings(to: file, over: URL(fileURLWithPath: $0)) } ?? Hooks.writeSettings(to: file)
                env[key] = file.path
            case .herdr: env["HERDR_SOCKET_PATH"] = socketPath; env["HERDR_PANE_ID"] = rec.id
            }
        } catch { Log.session.error("\(m.id, privacy: .public)'s hooks weren't written, its screen is read: \(error)") }
    }

    /// Where a session's Claude conversations are: under its profile's config dir when it has one.
    func claudeProjects(_ rec: Session) -> URL {
        rec.profile.flatMap { profile($0, agent: "claude") }.map { URL(fileURLWithPath: $0.dir).appendingPathComponent("projects") }
            ?? agentUsage.agentHomes.withLock { $0 }.claude
    }

    /// Account profiles keep each agent login in its own config dir: switching needs no re-login.
    static let configDirEnv = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = Self.configDirEnv[agent] else { return nil }
        for p in settings["accounts.profiles"]?.array ?? [] where p["name"]?.string == name && p["agent"]?.string == agent {
            if let d = p["dir"]?.string {
                Log.session.attempt("making profile \(name)'s folder") { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
                return (key, d)
            }
        }
        return nil
    }

    /// Paused rather than ended when its program stops with the daemon or sits idle, and back where it was when woken: an
    /// agent that resumes its conversation, a tmux terminal (tmux keeps the session, the wake attaches again).
    static func resumable(_ s: Session, _ manifests: [AgentManifest]) -> Bool {
        tmuxName(s) != nil || manifests.first { $0.id == s.agent }?.resumeArgs.isEmpty == false
    }

    /// The manifest its live session reads: with the hooks this launch wired, or none.
    func liveManifest(_ m: AgentManifest, cwd: String, worktreeId: String?, env: [String: String], argv: [String]) -> AgentManifest {
        wiredHooks(trustAnswered(m, cwd: cwd, worktreeId: worktreeId, env: env), env: env, argv: argv)
    }

    /// Only hooks this launch really wired report: not a remote session's (Kelp's files are on this Mac), nor one whose
    /// variable the user set themselves, whose file couldn't be written, or whose flag a custom command line left out.
    /// Those have their screen read instead.
    func wiredHooks(_ m: AgentManifest, env: [String: String], argv: [String]) -> AgentManifest {
        let dir = hooksDir(m)
        let wired = switch m.hooks {
        case .settingsFlag(let flag)?: argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
        case .pluginDir(let key)?: env[key] == dir.path
        case .settingsFile(let key, _)?: env[key] == dir.appendingPathExtension("json").path
        case .herdr?: env["HERDR_PANE_ID"] != nil
        case nil: false
        }
        var out = m
        if !wired { out.hooks = nil }
        return out
    }

    /// Pause agents that have sat idle (done / waiting) for `hibernateMinutes` with nobody watching.
    func hibernateIdle() {
        let minutes = settings.number("sessions.hibernateMinutes") ?? 0
        guard minutes > 0 else { return }
        // Only one a pause can bring back (`LiveSession.resumable`, known since its start: nothing is read on the tick).
        let candidates = live.all.filter { ls in
            ls.resumable && [.done, .waiting, .idle].contains(ls.snapshot.status) && !ls.isAttached && ls.idleSeconds > minutes * 60
        }.map { ($0, $0.inputs) }
        // Off the ticker: waiting for programs to exit (up to 3 s each) must not hold up status for everyone else.
        let start = pausingIdle.withLock { busy -> Bool in
            guard !busy, !candidates.isEmpty else { return false }
            busy = true; return true
        }
        guard start else { return }
        Thread.detachNewThread { [self] in
            for (ls, seen) in candidates { pauseIdle(ls, inputs: seen) }
            pausingIdle.withLock { $0 = false }
        }
    }

    /// Under its wake lock, as a wake is: one that comes meanwhile waits until this program is gone, so two never write one
    /// log. Taken out of `live` only if nobody attached and no input came since the check (`seen`): input never goes to a
    /// program that's about to be stopped. Input that comes once it's out waits for the pause and wakes it (`pausing`).
    func pauseIdle(_ ls: LiveSession, inputs seen: Int) {
        let id = ls.snapshot.id
        pausing.withLock { _ = $0.insert(id) }
        defer { pausing.withLock { _ = $0.remove(id) } }
        wakeLocks.withLock(id) {
            guard live.remove(ls, if: { $0.letGoIdle(seen: seen) }) else { return }
            hangUpStreams(ls)   // none by the check; one that came just after it ends too
            ls.markHibernated()
            Self.waitGone(ls.pty.terminate())   // SIGKILL after 2 s for what ignores the hangup: a wake must not start a second copy
            publishLast(ls)
        }
    }

    /// The agent's "trust this folder?" is answered by Kelp only when that question is actually coming and the user already
    /// settled it: the agent doesn't trust the session's folder yet (else it asks nothing, and an armed answer could only
    /// ever press a different menu) but does trust the project's main checkout. Anything else, including a repository it
    /// has never seen or one on a remote host, is the user's to answer.
    func trustAnswered(_ m: AgentManifest, cwd: String, worktreeId: String?, env: [String: String]) -> AgentManifest {
        guard m.autoAnswers.contains(AgentManifest.trust) else { return m }
        var out = m
        out.autoAnswers.removeAll { $0 == AgentManifest.trust }
        // A remote project's question is always the user's: decided before any git (over ssh, under its wake lock, for a host
        // that may not answer).
        guard remotes.of(cwd) == nil else { return out }
        // The project only counts for its own workspace's folder: any other cwd passed with its worktreeId is just a folder.
        // (A workspace on another branch of a trusted project is trusted the way Claude trusts a folder, whatever is checked
        // out in it.)
        var project: String?
        if let wid = worktreeId, let w = try? store.worktree(wid), let r = try? store.repo(w.repoId),
           AgentTrust.normal(cwd) == AgentTrust.normal(w.path) || AgentTrust.normal(cwd).hasPrefix(AgentTrust.normal(w.path) + "/"),
           !AgentConfig.changed(w.path, base: r.baseBranch, remotes: remotes) {
            project = r.path
        }
        // The config the agent will read: the session's variables over the daemon's own (a kelpd started from a shell
        // passes on that shell's CLAUDE_CONFIG_DIR), as PTY builds its environment.
        let env = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let expectedAndSettled = !AgentTrust.trusts(agent: m.id, folders: [cwd], env: env)
            && project.map { AgentTrust.trusts(agent: m.id, folders: [$0], env: env) } == true
        return expectedAndSettled ? m : out
    }

    /// Bring a paused session back under the same id (layout and links stay), resuming its conversation.
    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        wakeTries.withLock { $0 += 1 }
        guard var rec = try store.session(id), rec.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        let m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = resumeArgv(rec, m)
        rec.argv = argv   // the conversation it found is this session's from now on
        let env = launchEnv(m, rec)
        rec.status = .idle
        let ls = try LiveSession(record: rec, manifest: liveManifest(m, cwd: rec.cwd, worktreeId: rec.worktreeId, env: env, argv: argv),
                                 argv: try launchArgv(argv, cwd: rec.cwd, manifest: m, tmux: rec.tmux), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows, callbacks: callbacks(for: rec))
        if rec.tmux != nil { ls.attachedToRunning() }
        do { try live.add(ls) } catch {   // its record stays paused
            ls.discard()
            ls.start()
            throw error
        }
        publish(ls)
        ls.start()
        return ls
    }

    /// argv that brings back this session's own conversation. A remote one's conversations are on its host: the agent's
    /// own "latest in this folder" finds it there.
    func resumeArgv(_ rec: Session, _ m: AgentManifest) -> [String] {
        guard rec.agent == "claude", remotes.of(rec.cwd) == nil, let flag = m.resumeIdFlag, let pin = m.sessionIdFlag else { return m.resuming(rec.argv) }
        if let i = rec.argv.firstIndex(of: flag) {
            // Nothing was typed in the session this forks (`HomeSeed`): no conversation to copy, a new one of its own.
            if rec.argv.contains("--fork-session"), let id = rec.argv.dropFirst(i + 1).first,
               ClaudeHistory.session(id: id, cwd: rec.cwd, root: claudeProjects(rec)) == nil {
                return m.following(rec.argv, conversation: UUID().uuidString.lowercased())
            }
            return rec.argv
        }
        if let i = rec.argv.firstIndex(of: pin), i + 1 < rec.argv.count {
            // Pinned but nothing typed yet: no conversation to resume, start it under the same id.
            return ClaudeHistory.session(id: rec.argv[i + 1], cwd: rec.cwd, root: claudeProjects(rec)) != nil ? m.resuming(rec.argv) : rec.argv
        }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd, root: claudeProjects(rec))
        // From before ids were pinned (or restarted with "latest in this folder", which hands it another agent's
        // conversation): the first conversation that started here between this session and the next one, unless another
        // session has it; none → start fresh. Limit: misses prompts typed out of order across sessions.
        let base = rec.argv.filter { !m.resumeArgs.contains($0) }
        let all = (try? store.sessions()) ?? []
        let claimed = Set(all.filter { $0.id != rec.id }.flatMap { s in
            s.argv.indices.dropLast().filter { [pin, flag].contains(s.argv[$0]) }.map { s.argv[$0 + 1].lowercased() }
        })
        let next = all.filter { $0.agent == "claude" && $0.cwd == rec.cwd && $0.createdAt > rec.createdAt }.map(\.createdAt).min() ?? .distantFuture
        let own = conversations
            .filter { $0.started >= rec.createdAt.addingTimeInterval(-2) && $0.started < next && !claimed.contains($0.id.lowercased()) }
            .min { $0.started < $1.started }
        return own.map { base + [flag, $0.id] } ?? base
    }

    /// The conversation its hooks name is the one it continues: after /resume or /clear in Claude Code, a wake must bring
    /// back that one, not the id Kelp started it with (an old conversation under the new one's title).
    func follow(_ ls: LiveSession, transcript: String) {
        let conversation = URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent
        let s = ls.snapshot
        // Only a conversation's own file (a subagent's is agent-….jsonl), and the manifest read only when it changed: hooks come every turn.
        guard UUID(uuidString: conversation) != nil, !s.argv.contains(where: { $0.lowercased() == conversation.lowercased() }),
              let m = try? manifest(s.agent, command: nil, fallbackArgv: s.argv) else { return }
        let argv = m.following(s.argv, conversation: conversation)
        guard argv != s.argv else { return }
        _ = ls.update { $0.argv = argv }
        publish(ls)
    }

    /// A running session's record as it is when written, in order with its status changes (see LiveSession.emit): a copy
    /// taken on a request's thread could otherwise land after a newer status and put an old one back.
    /// Holds the session until it ran: one that just ended and left `live` still gets its last record saved.
    func publish(_ ls: LiveSession) {
        ls.inOrder { [weak self] in
            guard let self, !ls.isFinal else { return }
            save(ls.snapshot)
        }
    }

    /// On the session's status queue itself (its status callback): saved there and then. Queued again it would land after
    /// a pause queued meanwhile, and over the record of the wake that followed.
    func publishHere(_ ls: LiveSession) { if !ls.isFinal { save(ls.snapshot) } }

    /// A pause or an end, saved and said now, after every status change queued before it: one that read the record just
    /// before would otherwise write "working" over it, and a paused agent would never wake.
    func publishLast(_ ls: LiveSession) {
        let done = DispatchSemaphore(value: 0)
        ls.inOrder { [self] in
            save(ls.snapshot)
            ls.finish()
            done.signal()
        }
        done.wait()
    }

    /// A session that isn't running, changed in the store and said. A running one changes in its LiveSession and is
    /// published from there (`publish(ls)`): these are the only ways a session's record is written and sent.
    /// Read or unread, live or not: an agent that ended or paused unread is read at a glance too (its record only).
    func setUnread(_ id: String, _ on: Bool) throws {
        try wakeLocks.withLock(id) {   // not woken meanwhile: then the live session's own record would be the one
            if let ls = existing(id) {
                if ls.setUnread(on) != nil { publish(ls) }
            } else {
                try change(id) { $0.unread = on }
            }
        }
    }

    func change(_ id: String, _ body: (inout Session) -> Void) throws {
        if let s = try store.update(Session.self, id, body) { said(s) }
    }

    /// Only on the session's status queue (`publish(ls)`, `publishLast`), where the snapshot is the latest.
    private func save(_ snapshot: Session) {
        let s: Session
        do { s = try store.update(snapshot) } catch {
            // Deleted meanwhile (closed, its project removed): not brought back. Anything else (a full disk) is logged.
            if !(error is RecordError) { Log.store.error("couldn't save session \(snapshot.id, privacy: .public): \(error)") }
            return
        }
        said(s)
    }

    private func said(_ s: Session) {
        notify(s)
        watches.touched(.init(topic: .context, key: s.id), tag: s.status.rawValue)   // a turn ended or began: how full now
        if let ls = existing(s.id) { touchCommands(ls) }   // one ended with its turn or its program
        if s.status == .done || s.status == .waiting, let a = s.agent { agentUsage.planUsed(a) }
    }

    /// Its commands changed: whoever watches them reads them again.
    func touchCommands(_ ls: LiveSession) {
        watches.touched(.init(topic: .commands, key: ls.snapshot.id), tag: "\(ls.commandChanges)")
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    /// Runs git: call it off the cooperative pool (it's called on GCD).
    func autoTitle(session id: String, prompt: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.topic == nil else { return }   // the agent's own topic is better
        let title = Naming.title(prompt)
        let s = ls.update { if !$0.titleManual { $0.title = title } }
        publish(ls)
        guard let wid = s.worktreeId else { return }
        do {
            let renamed = try store.update(Worktree.self, wid) { w in
                if w.note.range(of: Workspaces.placeholderName, options: .regularExpression) != nil { w.note = title }
            }
            if renamed?.note == title { notify(ChangedEvent.worktree) }
            try nameBranch(wid, prompt: prompt, title: title)
        } catch { Log.session.error("couldn't name the workspace of \(id, privacy: .public) from its first prompt: \(error)") }
    }

    /// A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do. Folder
    /// and record agree after it either way: a record that couldn't be saved puts the folder's old name back.
    private func nameBranch(_ wid: String, prompt: String, title: String) throws {
        guard let w = try store.worktree(wid), w.branch.range(of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression) != nil,
              let r = try store.repo(w.repoId), w.path != r.path else { return }
        let base = Naming.slug(prompt)
        guard !base.isEmpty else { return }
        var b = base, n = 2
        while Git.branchExists(r.path, b, remotes: remotes) { b = "\(base)-\(n)"; n += 1 }
        try Git.renameBranch(w.path, from: w.branch, to: b, remotes: remotes)
        do { try store.update(Worktree.self, w.id) { $0.branch = b; if $0.note.isEmpty { $0.note = title } } } catch {
            do { try Git.renameBranch(w.path, from: b, to: w.branch, remotes: remotes) } catch {
                Log.session.error("branch \(b, privacy: .public) kept, its record says \(w.branch, privacy: .public): \(error)")
            }
            throw error
        }
        notify(ChangedEvent.worktree)
    }

    /// The agent's own short topic (Claude Code's terminal title) names the session instead of its prompt, and its
    /// workspace while that still has the name the session gave it (or a placeholder). A title set by hand stays.
    func retitle(session id: String, topic: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.snapshot.title != topic else { return }
        let old = ls.snapshot.title
        let s = ls.update { if !$0.titleManual { $0.title = topic } }
        publish(ls)
        let renamed = Log.store.attempt("naming the workspace after its first prompt") { try store.update(Worktree.self, s.worktreeId ?? "") { w in
            if (!old.isEmpty && w.note == old) || w.note.range(of: Workspaces.placeholderName, options: .regularExpression) != nil { w.note = topic }
        } } ?? nil
        if renamed?.note == topic { notify(ChangedEvent.worktree) }
    }

    func manifest(_ id: String?, command: String?, fallbackArgv: [String]? = nil) throws -> AgentManifest {
        if let command { return .custom(command) }
        if id == "custom", let a = fallbackArgv { return .init(id: "custom", name: "Custom", command: a.first ?? "/bin/zsh", args: Array(a.dropFirst())) }
        let id = id ?? "shell"
        // A plain shell has no meaningful "done": keep the heuristic quiet.
        if id == "shell" {
            return .init(id: "shell", name: "Shell", command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                         args: ["-l"], quietSeconds: 1e9)
        }
        guard let m = AgentManifest.load(dir: root.appendingPathComponent("agents")).first(where: { $0.id == id }) else {
            throw RPCError.invalidParams("unknown agent \(id)")
        }
        return m
    }

    /// Closing a desk ends its agents and forgets its layout; the folder is untouched. The last one stays.
    /// Out of sight, nothing lost: its agents pause (they resume their conversations when it comes back), its tabs stay.
    /// A workspace going out of sight: agents that can resume their conversation pause (they come back with it), the
    /// rest stop. Returns once their programs are gone, so nothing writes into the folder after this.
    func pauseSessions(of wid: String) throws {
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        var pids: [pid_t] = []
        // Under their wake locks, as idle pausing is: a wake that comes meanwhile waits until the programs are gone instead
        // of starting a second one (on the same log, in a folder about to be removed).
        let sessions = try store.sessions().filter { $0.worktreeId == wid }
        try wakeLocks.withLocks(sessions.map(\.id)) {
            for s in sessions { if let ls = live.remove(s.id) { pids += pause(ls, manifests) } }
            Self.waitGone(pids)
        }
    }

    /// A session already out of `live`: recorded as paused (a resumable agent) or ended — said here and saved now, since
    /// nothing records its exit any more — then stopped with all it started. Its pids, for `waitGone`.
    func pause(_ ls: LiveSession, _ manifests: [AgentManifest]) -> [pid_t] {
        hangUpStreams(ls)
        if Self.resumable(ls.snapshot, manifests) { ls.markHibernated() } else { ls.overrideStatus(.exited) }
        publishLast(ls)
        return ls.pty.terminate()   // SIGKILL after 2 s for what ignores the hangup, so all is gone within waitGone's 3
    }

    /// Until these processes have exited (or 3 s, for one that ignores the hangup).
    static func waitGone(_ pids: [pid_t]) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
    }
}
