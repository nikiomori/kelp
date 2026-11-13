import AgentData
import Core
import Foundation
import GitKit

// What `Watches` reads, asked as a client would ask it, and the records pushed as they change.

extension Daemon {
    /// A method answered as a client would get it (refusals and error mapping included), its result as its type.
    func ask<M: Answered>(_ method: M) async throws -> M.Result {
        try JSONDecoder().decode(M.Result.self, from: await answer(M.name, try method.params() ?? .null, conn: -1))
    }

    /// What a folder's branch committed since it left its project's base, for `GitEvent.branchFiles`. A base that
    /// isn't a branch here (a project made before it had one) says nothing, in the log.
    private func branchFiles(_ worktree: Worktree) async throws -> [String]? {
        guard let base = try store.repo(worktree.repoId)?.baseBranch, worktree.branch != base else { return nil }
        let remotes = remotes
        return try await offload {
            Log.store.attempt("\(worktree.branch)'s files since \(base)") {
                try Git.branchFiles(worktree.path, base: base, remotes: remotes)
            }
        }
    }

    /// A folder's pull request. Merged on the forge (a squash leaves the branch's commits out of the base): its group
    /// may be done with.
    private func prRead(_ key: String) async -> Data? {
        let pr = (try? await ask(GitHubBranchPR(worktreeId: key))) ?? nil
        if let pr, pr.state == "MERGED" {
            let workspaces = workspaces
            workspaces.headQueue.async { workspaces.tidyBranch(key, merged: pr) }
        }
        return pr.flatMap { line(PREvent(worktree: key, pr: $0)) }
    }

    /// A project's open pull requests, for the Issues panel and its number: other people's change on the forge only.
    private func prsRead(_ repo: String) async -> Data? {
        do { return line(PRsEvent(repo: repo, prs: try await ask(GitHubPRs(repoId: repo, filter: "open")))) } catch {
            return line(PRsEvent(repo: repo, error: error.rpcMessage))
        }
    }

    /// What only a branch group's folder holds (`GitEvent.only`, `dirty`); nothing to say for a project's own folder.
    private func ownWork(_ worktree: Worktree) async throws -> (Int?, Bool?) {
        guard let repo = try store.repo(worktree.repoId), repo.path != worktree.path else { return (nil, nil) }
        let remotes = remotes, workspaces = workspaces
        return try await offload {
            let branch = workspaces.branchNow(of: worktree, in: repo)
            return (
                Git.branchExists(repo.path, branch, remotes: remotes)
                    ? try Git.onlyOnBranch(repo: repo.path, branch, remotes: remotes) : 0,
                try Git.isDirty(worktree.path, remotes: remotes)
            )
        }
    }

    /// What a watch topic is, all of it here: which folder's file events can change it and which of them do (none: it
    /// goes by its clock; a remote project's folder here holds only its marker), how it's read now (the event as sent,
    /// nil when there's nothing to say, a failure that stays quiet; and when to read it again with nothing else saying
    /// so, nil: only when something does), and from which clock on its reads back off while nothing changes: what asks
    /// the network (gh, glab, ssh). Its reads hold the daemon until the watch stops.
    func topic(_ watch: Watches.Key) -> Watches.Topic {
        let key = watch.key
        switch watch.topic {
        case .git:
            return Watches.Topic(folder: workspaceFolder(key, ignoring: Git.touchesStatus), backsOffFrom: 10) {
                [self] _ in await gitRead(key)
            }
        case .ports:
            return Watches.Topic(backsOffFrom: 10) { [self] _ in
                // A host is asked over ssh: less often, and as with git only while watched.
                let remote = sessions.processes.remote(key) != nil
                return (
                    (try? await ask(PortsList(worktreeId: key))).flatMap { line(PortsEvent(worktree: key, ports: $0)) },
                    remote ? 10 : 3
                )
            }
        case .activity:
            return Watches.Topic { [self] _ in
                do { return (line(ActivityEvent(usage: try await ask(SessionUsage()))), 2) } catch {
                    return (line(ActivityEvent(error: error.rpcMessage)), 2)
                }
            }
        case .ci:
            // gh / glab ask the forge: often while a run goes on (or just after a push asked, `fast`), else every 2 minutes,
            // for a run started elsewhere (a merge on the forge, a push from another machine). A run going on isn't
            // slowed: its clock is short for a reason.
            return Watches.Topic(backsOffFrom: 120) { [self] fast in
                do {
                    let result = try await ask(CIRunsList(worktreeId: key))
                    let running = CIRuns.latest(result.runs).contains { $0.status != "completed" }
                    return (line(CIEvent(worktree: key, result: result)), running ? 10 : fast ? 5 : 120)
                } catch {   // no network yet after a wake, a slow gh: tried again, or the mark stays on this error
                    return (line(CIEvent(worktree: key, error: error.rpcMessage)), 120)
                }
            }
        case .pr:
            return Watches.Topic(backsOffFrom: 10) { [self] _ in (await prRead(key), 60) }
        case .prs:
            return Watches.Topic(backsOffFrom: 120) { [self] _ in (await prsRead(key), 120) }
        case .context:
            // A 1 MB transcript tail: while the agent works, and when its status changes (`touched`).
            return Watches.Topic { [self] _ in
                let usage = try? await ask(SessionContextWindow(id: key))
                let working = sessions.existing(key)?.snapshot.status == .working
                return (line(ContextEvent(session: key, usage: usage ?? nil)), working ? 15 : nil)
            }
        case .commands:
            // From memory; read again when one starts or ends (`Sessions.touchCommands`).
            return Watches.Topic { [self] _ in
                (line(CommandsEvent(session: key, commands: sessions.existing(key)?.commands ?? [])), nil)
            }
        case .subagents:
            // The tail of each one at work: only while a card or a journal is open, and a transcript says nothing of itself.
            return Watches.Topic { [self] _ in
                do {
                    return (line(SubagentsEvent(session: key, steps: try await ask(SessionSubagentSteps(id: key)))), 3)
                } catch { return (nil, 3) }
            }
        case .phone: return Watches.Topic { [self] _ in await phoneRead() }
        case .limits:
            // From memory (the probes read the plans on their own clock): cheap.
            return Watches.Topic { [self] _ in
                ((try? await ask(UsageGet())).flatMap { line(LimitsEvent(usage: $0)) }, 10)
            }
        case .file:
            guard key.hasPrefix("/"), remotes.containing(key) == nil else { return Watches.Topic { _ in (nil, nil) } }
            return Watches.Topic(folder: Self.fileFolder(key)) { [self] _ in await fileRead(key) }
        case .files:
            return Watches.Topic(folder: workspaceFolder(key, ignoring: Git.touchesFileList), backsOffFrom: 10) {
                [self] _ in await filesRead(key)
            }
        case .artifacts:
            return Watches.Topic(
                // A design's canvas is drawn with the project's design system: a change to it moves the canvas too.
                folder: workspaceFolder(key) { _ in
                    { $0.contains { $0.contains("/\(Artifacts.folder)/") || $0.contains("/\(DesignSystem.folder)/") } }
                }
            ) {
                [self] _ in (await artifacts(key), nil)
            }
        case .databases:
            // Its files are read again (a .env or compose file may have changed); what ran is in memory.
            return Watches.Topic(folder: workspaceFolder(key) { _ in { $0.contains(where: DatabaseFind.matters) } }) {
                [self] _ in
                do { return (line(try await ask(DatabaseActivity(worktreeId: key))), nil) } catch {
                    Log.session.error("reading workspace \(key)'s databases: \(error)")
                    return (nil, nil)
                }
            }
        case .machines:
            // Each machine's kelp-vm answers from memory; one with a command running is asked over its own connection who runs it.
            return Watches.Topic { [self] _ in
                do {
                    let all = try await ask(VMList())
                    return (
                        line(MachinesEvent(machines: all)),
                        all.contains { [.creating, .starting].contains($0.state) } ? 1 : 5
                    )
                } catch { return (nil, 5) }
            }
        case .machineDetail:
            return Watches.Topic { [self] _ in
                do { return (line(MachineEvent(name: key, detail: try await ask(VMDetailRead(name: key)))), 2) } catch {
                    return (nil, 2)
                }
            }
        case .host, .hostDetail:
            let again: TimeInterval = watch.topic == .host ? 10 : 2
            return Watches.Topic { [self] _ in
                do { return (line(HostEvent(stats: try await ask(HostStatsRead(host: key)))), again) } catch {
                    return (nil, again)
                }
            }
        }
    }

    /// A local workspace's folder, and which of its file events matter (made from its path); nil for a remote one.
    private func workspaceFolder(
        _ id: String, _ matters: (String) -> @Sendable ([String]) -> Bool
    ) -> (String, @Sendable ([String]) -> Bool)? {
        guard let worktree = store.look("workspace \(id)", { try $0.worktree(id) }), remotes.of(worktree.path) == nil
        else { return nil }
        return (worktree.path, matters(worktree.path))
    }

    /// The events `touches` counts, leaving out the folders git ignores.
    private func workspaceFolder(
        _ id: String, ignoring touches: @escaping @Sendable ([String]) -> Bool
    ) -> (String, @Sendable ([String]) -> Bool)? {
        let remotes = remotes
        return workspaceFolder(id) { path in
            let ignored = IgnoredFolders(root: path, remotes: remotes)
            return { touches(ignored.drop($0)) }
        }
    }

    private func gitRead(_ key: String) async -> (Data?, TimeInterval?) {
        // A remote project's folder here holds only its marker: no file events come, so it's read now and then.
        let worktree = store.look("workspace \(key)") { try $0.worktree(key) }
        let remote = worktree.map { remotes.of($0.path) != nil } ?? false
        var event: GitEvent
        do {
            let changes = try await ask(GitStatus(id: key))
            event = GitEvent(worktree: key, changes: changes, branches: try await ask(GitBranches(id: key)))
            event.stats = changes.isEmpty ? LineStats() : try? await ask(GitLineStats(id: key))
            if !remote, let worktree {
                event.branchFiles = try await branchFiles(worktree)
                (event.only, event.dirty) = try await ownWork(worktree)
            }
        } catch { event = GitEvent(worktree: key, error: error.rpcMessage) }
        return (line(event), remote ? 10 : nil)   // Limit: a remote folder is read every 10 s while watched
    }

    private func filesRead(_ key: String) async -> (Data?, TimeInterval?) {
        let remote = store.look("workspace \(key)") { try $0.worktree(key) }.map { remotes.of($0.path) != nil } ?? false
        var event: FilesEvent
        do {
            event = FilesEvent(
                worktree: key, paths: try await ask(FilesList(id: key)), ignored: try? await ask(FilesIgnored(id: key)))
        } catch { event = FilesEvent(worktree: key, error: error.rpcMessage) }
        return (line(event), remote ? 10 : nil)   // as git: a remote folder is listed every 10 s while watched
    }

    /// A file's folder, as FSEvents names it (/tmp is /private/tmp), and its events that name it: the file itself may
    /// not be there to resolve.
    /// Limit: a symlink's target changing elsewhere isn't seen; watch the target's folder if that matters.
    private static func fileFolder(_ path: String) -> (String, @Sendable ([String]) -> Bool) {
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let names = Set([path, ((Paths.real(dir) ?? dir) as NSString).appendingPathComponent(name)])
        return (dir, { $0.contains(where: names.contains) })
    }

    /// A stat: what changed is the version, not the text (the app reads that only for a version it doesn't hold).
    private func fileRead(_ path: String) async -> (Data?, TimeInterval?) {
        var problems: [CodeProblem] = []
        do { problems = try await ask(LSPProblems(path: path)) } catch {
            Log.session.error("reading \(path)'s problems: \(error)")
        }
        let event = FileEvent(path: path, stamp: FileService.stamp(path), problems: problems.isEmpty ? nil : problems)
        return (line(event), nil)
    }

    /// A workspace's artifacts, read on this Mac (a remote project's folder here holds only its marker). Every page
    /// is read, so off the pool; a failed read sends nothing, and the panel keeps what it had rather than going empty.
    /// Pages published before Kelp kept copies get theirs from their chats' transcripts after the list went out: what
    /// that writes pushes it again, with previews.
    private func artifacts(_ key: String) async -> Data? {
        let store = store, remotes = remotes
        do {
            let (root, items) = try await offload {
                try store.worktree(key).flatMap { worktree -> (String?, [ArtifactItem]) in
                    remotes.of(worktree.path) == nil ? (worktree.path, Artifacts.items(root: worktree.path)) : (nil, [])
                } ?? (nil, [])
            }
            if let root {
                Task {
                    do {
                        _ = try await offload {
                            Artifacts.recoverPages(root: root) { ClaudeHistory.transcript(id: $0) }
                        }
                    } catch {
                        Log.session.error("looking for old artifacts' pages in \(root): \(error)")
                    }
                }
            }
            return line(ArtifactsEvent(worktree: key, items: items))
        } catch {
            Log.session.error("reading workspace \(key) for its artifacts: \(error)")
            return nil
        }
    }

    /// The bridge to phones, every 2 s while Settings › Phone shows.
    private func phoneRead() async -> (Data?, TimeInterval?) {
        do { return (line(PhoneEvent(state: try await ask(PhoneStatus()))), 2) } catch { return (nil, 2) }
    }

    private func line(_ event: some RPCEvent) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard var data = try? enc.encode(RPCNotification(event)) else { return nil }
        data.append(0x0A)
        return data
    }

    /// A project or workspace record changed, or a record went: it goes to every client (they keep their lists from these).
    func recordChanged(_ change: Store.Change) {
        switch change {
        case .repo(let repo): notify(repo)
        case .worktree(let worktree): notify(worktree)
        case .repoRemoved(let id): notify(RemovedEvent(repo: id))
        case .worktreeRemoved(let id): notify(RemovedEvent(worktree: id))
        case .sessionRemoved(let id, _):
            notify(RemovedEvent(session: id))
            sessions.phone.hear(.removed(id))
        case .sessionEnded: break   // its record went out as it was saved
        }
    }
}

extension WatchStart: Handled {
    static var inOrder: Bool { true }   // a start and a stop sent in a row apply in that order
    /// A project's databases as the window sees them: hidden ones, All My Projects (hosts, users, keychain items)
    /// and the user's own statements. An agent asks `db.list` and `db.query`, which say what it may see.
    var notForAgents: String? {
        switch topic {
        case .databases: "The databases' activity is the user's: `kelp db list` says which an agent may use."
        case .phone: "The phones and their pairing link are the user's."
        default: nil
        }
    }
    func handle(_ watches: Watches, conn: Int) throws -> Done {
        watches.start(.init(topic: topic, key: key), conn: conn)
        return Done()
    }
}

extension WatchStop: Handled {
    static var inOrder: Bool { true }
    func handle(_ watches: Watches, conn: Int) throws -> Done {
        watches.stop(.init(topic: topic, key: key), conn: conn)
        return Done()
    }
}

extension Methods {
    static let watchMethods: [any Answered.Type] = [WatchStart.self, WatchStop.self]
}
