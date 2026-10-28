import Foundation
import Core
import GitKit

// What `Watches` reads, asked as a client would ask it, and the records pushed as they change.

extension Daemon {
    /// A method answered as a client would get it (refusals and error mapping included), its result as its type.
    func ask<M: Answered>(_ m: M) async throws -> M.Result {
        try JSONDecoder().decode(M.Result.self, from: await answer(M.name, try m.params() ?? .null, conn: -1))
    }

    /// The topic's event as it is now, as sent (nil: nothing to say, a failure that stays quiet), and when to read it
    /// again with nothing else saying so (nil: only when something does).
    func sample(_ k: Watches.Key, fast: Bool) async -> (Data?, TimeInterval?) {
        switch k.topic {
        case .git:
            // A remote project's folder here holds only its marker: no file events come, so it's read now and then.
            let remote = (try? store.worktree(k.key)).flatMap { $0 }.map { remotes.of($0.path) != nil } ?? false
            var e: GitEvent
            do {
                let changes = try await ask(GitStatus(id: k.key))
                e = GitEvent(worktree: k.key, changes: changes, branches: try await ask(GitBranches(id: k.key)))
                e.stats = changes.isEmpty ? LineStats() : try? await ask(GitLineStats(id: k.key))
            } catch { e = GitEvent(worktree: k.key, error: message(error)) }
            return (line(e), remote ? 10 : nil)   // Limit: a remote folder is read every 10 s while watched
        case .ports:
            return ((try? await ask(PortsList(worktreeId: k.key))).flatMap { line(PortsEvent(worktree: k.key, ports: $0)) }, 3)
        case .activity:
            do { return (line(ActivityEvent(usage: try await ask(SessionUsage()))), 2) }
            catch { return (line(ActivityEvent(error: message(error))), 2) }
        case .ci:
            // gh / glab ask the forge: often while a run goes on (or just after a push asked, `fast`), else every 2 minutes,
            // for a run started elsewhere (a merge on the forge, a push from another machine).
            do {
                let r = try await ask(CIRunsList(worktreeId: k.key))
                let running = CIRuns.latest(r.runs).contains { $0.status != "completed" }
                return (line(CIEvent(worktree: k.key, result: r)), running ? 10 : fast ? 5 : 120)
            } catch { return (line(CIEvent(worktree: k.key, error: message(error))), nil) }
        case .pr:
            return ((try? await ask(GitHubBranchPR(worktreeId: k.key))).flatMap { line(PREvent(worktree: k.key, pr: $0)) }, 60)
        case .context:
            // A 1 MB transcript tail: while the agent works, and when its status changes (`touched`).
            let usage = try? await ask(SessionContextWindow(id: k.key))
            let working = sessions.existing(k.key)?.snapshot.status == .working
            return (line(ContextEvent(session: k.key, usage: usage ?? nil)), working ? 15 : nil)
        case .commands:
            // From memory; read again when one starts or ends (`Sessions.touchCommands`).
            return (line(CommandsEvent(session: k.key, commands: sessions.existing(k.key)?.commands ?? [])), nil)
        case .limits:
            // From memory (the probes read the plans on their own clock): cheap.
            return ((try? await ask(UsageGet())).flatMap { line(LimitsEvent(usage: $0)) }, 10)
        case .file:
            // A stat: what changed is the version, not the text (the app reads that only for a version it doesn't hold).
            guard k.key.hasPrefix("/"), remotes.containing(k.key) == nil else { return (nil, nil) }
            return (line(FileEvent(path: k.key, stamp: FileService.stamp(k.key))), nil)
        case .files:
            let remote = (try? store.worktree(k.key)).flatMap { $0 }.map { remotes.of($0.path) != nil } ?? false
            var e: FilesEvent
            do {
                e = FilesEvent(worktree: k.key, paths: try await ask(FilesList(id: k.key)), ignored: try? await ask(FilesIgnored(id: k.key)))
            } catch { e = FilesEvent(worktree: k.key, error: message(error)) }
            return (line(e), remote ? 10 : nil)   // as git: a remote folder is listed every 10 s while watched
        }
    }

    private func line(_ e: some RPCEvent) -> Data? {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        guard var d = try? enc.encode(RPCNotification(e)) else { return nil }
        d.append(0x0A)
        return d
    }

    private func message(_ e: Error) -> String { (e as? RPCError)?.message ?? "\(e)" }

    /// A project or workspace record changed, or a record went: it goes to every client (they keep their lists from these).
    func recordChanged(_ c: Store.Change) {
        switch c {
        case .repo(let r): notify(r)
        case .worktree(let w): notify(w)
        case .repoRemoved(let id): notify(RemovedEvent(repo: id))
        case .worktreeRemoved(let id): notify(RemovedEvent(worktree: id))
        case .sessionRemoved(let id): notify(RemovedEvent(session: id))
        }
    }
}

extension WatchStart: Handled {
    static var inOrder: Bool { true }   // a start and a stop sent in a row apply in that order
    func handle(_ watches: Watches) throws -> Done { throw RPCError.internalError("needs its connection") }
    func handle(_ watches: Watches, conn: Int) throws -> Done { watches.start(.init(topic: topic, key: key), conn: conn); return Done() }
}

extension WatchStop: Handled {
    static var inOrder: Bool { true }
    func handle(_ watches: Watches) throws -> Done { throw RPCError.internalError("needs its connection") }
    func handle(_ watches: Watches, conn: Int) throws -> Done { watches.stop(.init(topic: topic, key: key), conn: conn); return Done() }
}
