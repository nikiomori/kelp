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

    /// The topic's event as it is now, as sent (nil: nothing to say, a failure that stays quiet), and when to read it
    /// again with nothing else saying so (nil: only when something does).
    func sample(_ watch: Watches.Key, fast: Bool) async -> (Data?, TimeInterval?) {
        let key = watch.key
        switch watch.topic {
        case .git:
            // A remote project's folder here holds only its marker: no file events come, so it's read now and then.
            let worktree = (try? store.worktree(key)).flatMap { $0 }
            let remote = worktree.map { remotes.of($0.path) != nil } ?? false
            var event: GitEvent
            do {
                let changes = try await ask(GitStatus(id: key))
                event = GitEvent(worktree: key, changes: changes, branches: try await ask(GitBranches(id: key)))
                event.stats = changes.isEmpty ? LineStats() : try? await ask(GitLineStats(id: key))
                if !remote, let worktree { event.branchFiles = try await branchFiles(worktree) }
            } catch { event = GitEvent(worktree: key, error: error.rpcMessage) }
            return (line(event), remote ? 10 : nil)   // Limit: a remote folder is read every 10 s while watched
        case .ports:
            // A host is asked over ssh: less often, and as with git only while watched.
            let remote = sessions.processes.remote(key) != nil
            return (
                (try? await ask(PortsList(worktreeId: key))).flatMap { line(PortsEvent(worktree: key, ports: $0)) },
                remote ? 10 : 3
            )
        case .activity:
            do { return (line(ActivityEvent(usage: try await ask(SessionUsage()))), 2) } catch {
                return (line(ActivityEvent(error: error.rpcMessage)), 2)
            }
        case .ci:
            // gh / glab ask the forge: often while a run goes on (or just after a push asked, `fast`), else every 2 minutes,
            // for a run started elsewhere (a merge on the forge, a push from another machine).
            do {
                let result = try await ask(CIRunsList(worktreeId: key))
                let running = CIRuns.latest(result.runs).contains { $0.status != "completed" }
                return (line(CIEvent(worktree: key, result: result)), running ? 10 : fast ? 5 : 120)
            } catch {   // no network yet after a wake, a slow gh: tried again, or the mark stays on this error
                return (line(CIEvent(worktree: key, error: error.rpcMessage)), 120)
            }
        case .pr:
            return (
                (try? await ask(GitHubBranchPR(worktreeId: key))).flatMap { line(PREvent(worktree: key, pr: $0)) },
                60
            )
        case .context:
            // A 1 MB transcript tail: while the agent works, and when its status changes (`touched`).
            let usage = try? await ask(SessionContextWindow(id: key))
            let working = sessions.existing(key)?.snapshot.status == .working
            return (line(ContextEvent(session: key, usage: usage ?? nil)), working ? 15 : nil)
        case .commands:
            // From memory; read again when one starts or ends (`Sessions.touchCommands`).
            return (line(CommandsEvent(session: key, commands: sessions.existing(key)?.commands ?? [])), nil)
        case .subagents:
            // The tail of each one at work: only while a card or a journal is open, and a transcript says nothing of itself.
            do {
                return (line(SubagentsEvent(session: key, steps: try await ask(SessionSubagentSteps(id: key)))), 3)
            } catch { return (nil, 3) }
        case .limits:
            // From memory (the probes read the plans on their own clock): cheap.
            return ((try? await ask(UsageGet())).flatMap { line(LimitsEvent(usage: $0)) }, 10)
        case .file:
            // A stat: what changed is the version, not the text (the app reads that only for a version it doesn't hold).
            guard key.hasPrefix("/"), remotes.containing(key) == nil else { return (nil, nil) }
            var problems: [CodeProblem] = []
            do { problems = try await ask(LSPProblems(path: key)) } catch {
                Log.session.error("reading \(key)'s problems: \(error)")
            }
            return (
                line(
                    FileEvent(path: key, stamp: FileService.stamp(key), problems: problems.isEmpty ? nil : problems)
                ), nil
            )
        case .files:
            let remote = (try? store.worktree(key)).flatMap { $0 }.map { remotes.of($0.path) != nil } ?? false
            var event: FilesEvent
            do {
                event = FilesEvent(
                    worktree: key, paths: try await ask(FilesList(id: key)),
                    ignored: try? await ask(FilesIgnored(id: key)))
            } catch { event = FilesEvent(worktree: key, error: error.rpcMessage) }
            return (line(event), remote ? 10 : nil)   // as git: a remote folder is listed every 10 s while watched
        case .artifacts:
            // Read on this Mac: a remote project's folder here holds only its marker. Every page is read, so off the pool;
            // a failed read sends nothing, and the panel keeps what it had rather than going empty.
            let store = store, remotes = remotes
            do {
                let items = try await offload {
                    try store.worktree(key).flatMap {
                        remotes.of($0.path) == nil ? Artifacts.items(root: $0.path) : []
                    } ?? []
                }
                return (line(ArtifactsEvent(worktree: key, items: items)), nil)
            } catch {
                Log.session.error("reading workspace \(key) for its artifacts: \(error)")
                return (nil, nil)
            }
        case .databases:
            // Its files are read again (a .env or compose file may have changed); what ran is in memory.
            do { return (line(try await ask(DatabaseActivity(worktreeId: key))), nil) } catch {
                Log.session.error("reading workspace \(key)'s databases: \(error)")
                return (nil, nil)
            }
        case .machines:
            // Each machine's kelp-vm answers from memory; one with a command running is asked over its own connection who runs it.
            do {
                let all = try await ask(VMList())
                return (
                    line(MachinesEvent(machines: all)),
                    all.contains { [.creating, .starting].contains($0.state) } ? 1 : 5
                )
            } catch { return (nil, 5) }
        case .machineDetail:
            do { return (line(MachineEvent(name: key, detail: try await ask(VMDetailRead(name: key)))), 2) } catch {
                return (nil, 2)
            }
        case .host, .hostDetail:
            let again: TimeInterval = watch.topic == .host ? 10 : 2
            do { return (line(HostEvent(stats: try await ask(HostStatsRead(host: key)))), again) } catch {
                return (nil, again)
            }
        }
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
        case .sessionRemoved(let id): notify(RemovedEvent(session: id))
        }
    }
}

extension WatchStart: Handled {
    static var inOrder: Bool { true }   // a start and a stop sent in a row apply in that order
    /// A project's databases as the window sees them: hidden ones, All My Projects (hosts, users, keychain items)
    /// and the user's own statements. An agent asks `db.list` and `db.query`, which say what it may see.
    var notForAgents: String? {
        topic == .databases ? "The databases' activity is the user's: `kelp db list` says which an agent may use." : nil
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
