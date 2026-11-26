import AgentData
import Core
import Foundation
import GitKit
import os

// What `Watches` reads for each topic, asked as a client would ask it (`ask`, Server.swift).

extension Daemon {
    /// The files a folder's branch committed since it left its project's base, for `GitEvent.branchFiles`. A base that
    /// isn't a branch here (a project made before it had one) gives nil, with a note in the log.
    private func branchFiles(_ worktree: Worktree) async throws -> [String]? {
        guard let base = try store.repo(worktree.repoId)?.baseBranch, worktree.branch != base else { return nil }
        let remotes = remotes
        return try await offload {
            Log.store.attempt("\(worktree.branch)'s files since \(base)") {
                try Git.branchFiles(worktree.path, base: base, remotes: remotes)
            }
        }
    }

    /// Reads a folder's pull request. When it was merged on the forge (a squash leaves the branch's commits out of the
    /// base), the folder's group may no longer be needed.
    private func prRead(_ key: String) async -> Data? {
        let pr = await logged(.pr, key) { try await ask(GitHubBranchPR(worktreeId: key)) } ?? nil
        if let pr, pr.state == "MERGED" {
            let workspaces = workspaces
            workspaces.headQueue.async { workspaces.tidyBranch(key, merged: pr) }
        }
        return pr.flatMap { line(PREvent(worktree: key, pr: $0)) }
    }

    /// A project's open pull requests (Issues panel and count). Only the forge changes them, so no folder is watched.
    private func prsRead(_ repo: String) async -> Data? {
        do { return line(PRsEvent(repo: repo, prs: try await ask(GitHubPRs(repoId: repo, filter: .open)))) } catch {
            return line(PRsEvent(repo: repo, error: error.rpcMessage))
        }
    }

    /// How much only a branch group's folder holds (`GitEvent.only`). Returns nil for a project's own folder.
    private func ownWork(_ worktree: Worktree, in repo: Repo?) async throws -> Int? {
        guard let repo, repo.path != worktree.path else { return nil }
        let remotes = remotes, workspaces = workspaces
        return try await offload {
            let branch = workspaces.branchNow(of: worktree, in: repo)
            return Git.branchExists(repo.path, branch, remotes: remotes)
                ? try Git.onlyOnBranch(repo: repo.path, branch, remotes: remotes) : 0
        }
    }

    /// A local folder's `branchFiles`, `only` and `dirty`. The first two are read again only once its branches read
    /// differently than last time (`memo`), since an agent writing files changes neither. `dirty` is the status just
    /// read. Limit: another branch's tip isn't in `BranchInfo`, so the base taking this branch in is seen only at this
    /// branch's next commit.
    private func branchWork(
        _ worktree: Worktree, _ branches: BranchInfo, _ changes: [FileChange], _ memo: BranchMemo
    ) async throws -> (files: [String]?, only: Int?, dirty: Bool?) {
        let repo = try store.repo(worktree.repoId)
        let dirty = repo.map { $0.path != worktree.path } == true ? Git.isDirty(changes, in: worktree.path) : nil
        let seen = BranchMemo.Seen(branches: branches, base: repo?.baseBranch, branch: worktree.branch)
        if let known = memo.known(seen) { return (known.files, known.only, dirty) }
        async let files = branchFiles(worktree)
        let only = try await ownWork(worktree, in: repo)
        let work = (files: try await files, only: only)
        memo.keep(seen, work)
        return (work.files, work.only, dirty)
    }

    /// Counts lines added and removed. New files are those the status listed, unless it listed only `FileChange.limit`.
    private func lineStats(_ key: String, local worktree: Worktree?, _ changes: [FileChange]) async -> LineStats? {
        guard !changes.isEmpty else { return LineStats() }
        let remotes = remotes
        let untracked = changes.count < FileChange.limit ? changes.filter(\.untracked).map(\.path) : nil
        do {
            guard let path = worktree?.path else { return try await ask(GitLineStats(id: key)) }
            return try await offload { try Git.lineStats(path, untracked: untracked, remotes: remotes) }
        } catch { return nil }   // the counts are a decoration: none rather than a failed read
    }

    /// Describes each watch topic, all in one place:
    /// - which folder's file events can change it, and which of those events do (none when it goes by its clock alone;
    /// for a remote project, the folder here holds only its marker);
    /// - how it is read now: the event as sent, nil when there is nothing to say or a failure stays quiet, and when to
    /// read it again if nothing else asks (nil: only when something does);
    /// - the interval from which its reads back off while nothing changes, for network topics (gh, glab, ssh).
    /// A topic's reads hold the daemon until the watch stops.
    func topic(_ watch: Watches.Key) -> Watches.Topic {
        let key = watch.key
        switch watch.topic {
        case .git:
            let first = FirstRead(), memo = BranchMemo()
            return Watches.Topic(
                folder: workspaceFolder(key, ignoring: { Git.touchesStatus($0.map(\.path)) }), backsOffFrom: 10
            ) {
                [self] _ in await gitRead(key, first: first.take(), memo: memo)
            }
        case .ports:
            return Watches.Topic(backsOffFrom: 10) { [self] _ in
                // A host is asked over ssh, so less often, and as with git only while watched.
                let remote = sessions.processes.remote(key) != nil
                let ports = await logged(.ports, key) { try await ask(PortsList(worktreeId: key)) }
                return (ports.flatMap { line(PortsEvent(worktree: key, ports: $0)) }, remote ? 10 : 3)
            }
        case .activity:
            return Watches.Topic { [self] _ in
                do { return (line(ActivityEvent(usage: try await ask(SessionUsage()))), 2) } catch {
                    return (line(ActivityEvent(error: error.rpcMessage)), 2)
                }
            }
        case .ci:
            // gh / glab ask the forge often while a run goes on (or just after a push asked, `fast`), and otherwise
            // every 2 minutes, to catch a run started elsewhere (a merge on the forge, a push from another machine). A
            // run going on isn't slowed, because its clock is short for a reason.
            return Watches.Topic(backsOffFrom: 120) { [self] fast in
                do {
                    let result = try await ask(CIRunsList(worktreeId: key))
                    let running = CIRuns.latest(result.runs).contains { $0.status != "completed" }
                    return (line(CIEvent(worktree: key, result: result)), running ? 10 : fast ? 5 : 120)
                } catch {   // no network after a wake, or a slow gh: tried again, else the mark shows this error
                    return (line(CIEvent(worktree: key, error: error.rpcMessage)), 120)
                }
            }
        case .pr:
            return Watches.Topic(backsOffFrom: 10) { [self] _ in (await prRead(key), 60) }
        case .prs:
            return Watches.Topic(backsOffFrom: 120) { [self] _ in (await prsRead(key), 120) }
        case .context:
            // Reading a 1 MB tail, the topic polls only while the agent works, and on a status change (`touched`).
            return Watches.Topic { [self] _ in
                let usage = await logged(.context, key) { try await ask(SessionContextWindow(id: key)) }
                let working = sessions.existing(key)?.snapshot.status == .working
                return (line(ContextEvent(session: key, usage: usage ?? nil)), working ? 15 : nil)
            }
        case .commands, .edits: return agentTools(watch)
        case .subagents:   // each working subagent's tail while a card or journal is open: a transcript sends no events
            return Watches.Topic { [self] _ in
                let steps = await logged(.subagents, key) { try await ask(SessionSubagentSteps(id: key)) }
                return (steps.flatMap { line(SubagentsEvent(session: key, steps: $0)) }, 3)
            }
        case .work: return Watches.Topic { [self, reader = WorkReader.of(self)] _ in   // a transcript sends no events
                ((await logged(.work, key) { try await offload { try reader.event(key) } } ?? nil).flatMap(line), 2) }
        case .phone: return Watches.Topic { [self] _ in await phoneRead() }
        case .limits:
            // Read from memory (the probes read the plans on their own clock), so cheap. Token totals are read again
            // only while Kelp's window is seen; the limits always are, for their notifications and the Dock.
            return Watches.Topic { [self] _ in
                let away = clients.uiState.away == true ? true : nil
                let usage = await logged(.limits, key) { try await ask(UsageGet(cachedTokens: away)) }
                return (usage.flatMap { line(LimitsEvent(usage: $0)) }, 10)
            }
        case .file:
            guard key.hasPrefix("/") else { return Watches.Topic { _ in (nil, nil) } }
            if let located = remotes.containing(key) {   // no file events from a host: the digest is read there
                let first = FirstRead()
                return Watches.Topic(backsOffFrom: 10) { [self] _ in
                    await hostFileRead(key, located.remote, located.remotePath, first: first.take())
                }
            }
            return Watches.Topic(folder: Watches.fileFolder(key)) { [self] _ in await fileRead(key) }
        case .files:
            let first = FirstRead()
            return Watches.Topic(folder: workspaceFolder(key, ignoring: Git.touchesFileList), backsOffFrom: 10) {
                [self] _ in await filesRead(key, first: first.take())
            }
        case .artifacts: return artifactsTopic(key)
        case .databases:
            // The workspace's files are read again (a .env or compose file may have changed); what ran is in memory.
            return Watches.Topic(
                folder: workspaceFolder(key) { _ in { $0.contains { DatabaseFind.matters($0.path) } } }
            ) {
                [self] _ in
                do { return (line(try await ask(DatabaseActivity(worktreeId: key))), nil) } catch {
                    Log.session.error("reading workspace \(key)'s databases: \(error)")
                    // The panel is told, or it would wait for an answer that isn't coming.
                    return (line(DatabasesEvent(worktree: key, databases: [], runs: [], error: error.rpcMessage)), nil)
                }
            }
        case .machines:
            // Each machine's kelp-vm answers from memory. A machine with a command running is asked over its own
            // connection who runs it.
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

    /// A local workspace's folder and which of its file events matter (made from its path), or nil when remote.
    private func workspaceFolder(
        _ id: String, _ matters: (String) -> @Sendable ([FileWatcher.Change]) -> Bool
    ) -> (String, @Sendable ([FileWatcher.Change]) -> Bool)? {
        guard let worktree = store.look("workspace \(id)", { try $0.gitPlace(id) }), remotes.of(worktree.path) == nil
        else { return nil }
        return (worktree.path, matters(worktree.path))
    }

    /// A local workspace's folder, as above, with the file events `touches` counts, minus the folders git ignores.
    private func workspaceFolder(
        _ id: String, ignoring touches: @escaping @Sendable ([FileWatcher.Change]) -> Bool
    ) -> (String, @Sendable ([FileWatcher.Change]) -> Bool)? {
        let remotes = remotes
        return workspaceFolder(id) { path in
            let ignored = IgnoredFolders(root: path, remotes: remotes)
            return { touches(ignored.drop($0)) }
        }
    }

    /// Reads the status and branches, or in a folder of repositories (`RepoKey`) each one's, summed up.
    private func gitRead(_ key: String, first: Bool, memo: BranchMemo) async -> (Data?, TimeInterval?) {
        // A remote project's folder here holds only its marker: no file events come, so it's read now and then.
        let worktree = store.look("workspace \(key)") { try $0.gitPlace(key) }
        let remote = worktree.map { remotes.of($0.path) != nil } ?? false
        guard await mayRead(worktree, first: first) else { return (nil, 10) }
        let names = remote ? [] : worktree.map { Git.nestedRepos($0.path) } ?? []   // a folder of repositories
        let event = await names.isEmpty
            ? gitEvent(key, worktree, remote: remote, memo: memo)
            : GitEvent.sum(key, names) { await gitEvent($0, nil, remote: false, memo: memo.inner($1)) }
        return (line(event), remote ? 10 : nil)   // Limit: a remote folder is read every 10 s while watched
    }

    /// One folder's status and branches, read at once, then from them the line counts and what the branch holds.
    private func gitEvent(_ key: String, _ given: Worktree?, remote: Bool, memo: BranchMemo) async -> GitEvent {
        let worktree = given ?? store.look("workspace \(key)") { try $0.gitPlace(key) }
        var event: GitEvent
        do {
            async let branchesRead = direct(GitBranches(id: key))
            let changes = try await direct(GitStatus(id: key))
            async let stats = lineStats(key, local: remote ? nil : worktree, changes)
            let branches = try await branchesRead
            event = GitEvent(worktree: key, changes: changes, branches: branches)
            if !remote, let worktree {
                (event.branchFiles, event.only, event.dirty) = try await branchWork(worktree, branches, changes, memo)
            }
            event.stats = await stats
            // A remote project's branch has no file events to follow, so its workspace takes the branch git just read.
            if remote, let worktree, let current = event.branches?.current, current != worktree.branch {
                let store = store
                Log.store.attempt("following \(worktree.path)'s branch") {
                    _ = try store.update(Worktree.self, worktree.id) { $0.branch = current }
                }
            }
        } catch { event = GitEvent(worktree: key, error: error.rpcMessage) }
        return event
    }

    private func filesRead(_ key: String, first: Bool) async -> (Data?, TimeInterval?) {
        let worktree = store.look("workspace \(key)") { try $0.worktree(key) }
        let remote = worktree.map { remotes.of($0.path) != nil } ?? false
        guard await mayRead(worktree, first: first) else { return (nil, 10) }
        var event: FilesEvent
        do {
            event = FilesEvent(
                worktree: key, paths: try await direct(FilesList(id: key)),
                ignored: try? await direct(FilesIgnored(id: key)))
        } catch { event = FilesEvent(worktree: key, error: error.rpcMessage) }
        return (line(event), remote ? 10 : nil)   // as for git, a remote folder is listed every 10 s while watched
    }

    /// Whether a watch of `worktree` reads now. It always does on this Mac. On a host it reads over a connection
    /// already open, or on the watch's first read, when someone just showed it. A poll never dials a host, so until
    /// something connects (a terminal, an agent, Connect), the panel keeps what it showed.
    private func mayRead(_ worktree: Worktree?, first: Bool) async -> Bool {
        guard !first, let remote = worktree.flatMap({ remotes.of($0.path) }) else { return true }
        do { return try await offload { remote.connection != nil } } catch { return false }
    }

    /// Reads a file's stat and problems. What changes is the version, not the text (the app reads the text only for a
    /// version it doesn't hold).
    private func fileRead(_ path: String) async -> (Data?, TimeInterval?) {
        var problems: [CodeProblem] = []
        do { problems = try await ask(LSPProblems(path: path)) } catch {
            Log.session.error("reading \(path)'s problems: \(error)")
        }
        let event = FileEvent(path: path, stamp: FileService.stamp(path), problems: problems.isEmpty ? nil : problems)
        return (line(event), nil)
    }

    /// Read when the artifacts in the folder change, including a remote project's folder, which keeps the pages its
    /// agents publish on the host (`pickUpHostArtifacts`). A design's canvas is drawn with the project's design system,
    /// so a change to the design system changes the canvas too.
    private func artifactsTopic(_ key: String) -> Watches.Topic {
        let root = store.look("workspace \(key)") { try $0.worktree(key) }?.path
        let matters: @Sendable ([FileWatcher.Change]) -> Bool = {
            $0.contains { $0.path.contains("/\(Artifacts.folder)/") || $0.path.contains("/\(DesignSystem.folder)/") }
        }
        return Watches.Topic(folder: root.map { ($0, matters) }) { [self] _ in (await artifacts(key), nil) }
    }

    /// Reads a remote project's open file. Its version is its bytes' digest (`FileService.digest`), read on the host
    /// every 10 s (60 s once it's quiet). After the first read, it is read only over a connection already open. A file
    /// that is gone has no version.
    private func hostFileRead(_ key: String, _ remote: RemoteHost, _ path: String, first: Bool) async
        -> (Data?, TimeInterval?)
    {
        let script =
            "f=\(ShellQuote.word(path)); "
            + #"[ -f "$f" ] || { echo missing; exit 0; }; { sha256sum -- "$f" 2>/dev/null || shasum -a 256 -- "$f"; } | cut -d' ' -f1"#
        let out: String?
        do {
            out = try await offload { () -> String? in
                guard first || remote.connection != nil else { return nil }
                return String(decoding: try remote.run(script, timeLimit: 20), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { out = nil }
        guard let said = out, !said.isEmpty else { return (nil, 10) }   // not asked, or host away: keep what's shown
        let stamp = said == "missing" ? nil : "sha256:" + said
        return (line(FileEvent(path: key, stamp: stamp)), 10)
    }

    /// Reads a workspace's artifacts, as its folder here keeps them. For a remote project, its chats are asked on the
    /// host first for pages they published there. Every page is read, so this runs off the pool. A failed read sends
    /// nothing, and the panel keeps what it had rather than going empty. Pages published before Kelp kept copies get
    /// their copies from their chats' transcripts after the list went out, and what that writes pushes the list again,
    /// with previews.
    private func artifacts(_ key: String) async -> Data? {
        let store = store, remotes = remotes, sessions = sessions
        do {
            let (root, items) = try await offload {
                try store.worktree(key).map { worktree -> (String?, [ArtifactItem]) in
                    guard remotes.of(worktree.path) != nil else {
                        return (worktree.path, Artifacts.items(root: worktree.path))
                    }
                    for chat in try store.sessions() where chat.worktreeId == key {
                        try sessions.pickUpHostArtifacts(of: chat, in: worktree.path)
                    }
                    return (nil, Artifacts.items(root: worktree.path))
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
            return line(ArtifactsEvent(worktree: key, items: [], error: error.rpcMessage))   // the panel is told
        }
    }

    /// The bridge to phones, every 2 s while Settings › Phone shows.
    private func phoneRead() async -> (Data?, TimeInterval?) {
        do { return (line(PhoneEvent(state: try await ask(PhoneStatus()))), 2) } catch { return (nil, 2) }
    }

    /// What an agent's tools did, read from memory, and read again when its hooks tell more (`Sessions.touchCommands`,
    /// `touchEdits`).
    private func agentTools(_ watch: Watches.Key) -> Watches.Topic {
        let key = watch.key
        return Watches.Topic { [self] _ in
            guard watch.topic == .edits else {
                return (line(CommandsEvent(session: key, commands: sessions.existing(key)?.commands ?? [])), nil)
            }
            let last = sessions.existing(key)?.lastEdit
            return (line(EditsEvent(session: key, path: last?.path, count: last?.count ?? 0)), nil)
        }
    }

    /// Returns what `read` gives, or nil on a failure, which the log explains (`Watches.failed`).
    private func logged<T>(_ topic: WatchTopic, _ key: String, _ read: () async throws -> T) async -> T? {
        do { return try await read() } catch {
            watches.failed(.init(topic: topic, key: key), error.rpcMessage)
            return nil
        }
    }

    private func line(_ event: some RPCEvent) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard var data = try? enc.encode(RPCNotification(event)) else { return nil }
        data.append(0x0A)
        return data
    }
}
