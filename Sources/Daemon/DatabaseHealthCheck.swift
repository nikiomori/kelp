import Core
import Foundation
import os

/// The panel's dots: each database tried once (SELECT 1, a few seconds at most), side by side. A server reached over
/// SSH, or a remote project's, is tried only through a connection that's open already: the panel never dials.
extension Databases {
    func status(_ worktreeId: String, library: Bool = false) async throws -> [DatabaseHealth] {
        let all = try await offloads.run { [self] in
            library ? try self.library().compactMap { try libraryConnection($0.name) } : try connections(worktreeId)
        }
        let path = try store.worktree(worktreeId)?.path ?? ""
        let remote = library ? nil : remotes.of(path)   // All My Projects' aren't on the project's host
        return await withTaskGroup(of: (Int, DatabaseHealth).self) { group in
            for (index, c) in all.enumerated() {
                group.addTask { [self] in
                    let late = DatabaseHealth(
                        name: c.database.name, state: .unknown,
                        reason: "It didn't answer in \(Int(Self.healthTime)) s.")
                    return (
                        index,
                        await Self.answer(within: Self.healthTime, or: late) {
                            await self.health(c, worktreeId, remote: remote)
                        }
                    )
                }
            }
            var out: [(Int, DatabaseHealth)] = []
            for await one in group { out.append(one) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One database's whole check (an SSH check, a connect, SELECT 1, compose's word): one that takes longer is
    /// said as such, so the others' dots come back within `DatabaseStatus`' time.
    static let healthTime: TimeInterval = 20

    /// What `work` answers, or `late` once `seconds` have passed (the work goes on, its answer dropped).
    static func answer<T: Sendable>(
        within seconds: TimeInterval, or late: T, _ work: @escaping @Sendable () async -> T
    ) async -> T {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>(initialState: nil)
        @Sendable func give(_ value: T) {
            let continuation = waiting.withLock { held in
                defer { held = nil }
                return held
            }
            continuation?.resume(returning: value)
        }
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            Task { give(await work()) }
            Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                give(late)
            }
        }
    }

    private func health(_ c: DatabaseConnection, _ worktreeId: String, remote: RemoteHost?) async -> DatabaseHealth {
        let name = c.database.name
        if c.database.engine.isFile {
            let there = c.database.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return DatabaseHealth(name: name, state: there ? .ok : .down, reason: there ? nil : "The file isn't there.")
        }
        if c.database.source != nil, remote == nil, c.database.ssh == nil, let host = c.database.host,
            !DatabaseFind.isLocal(host)
        {
            // An address from the project's files (a cloned repo's .env): dialled when the user opens it, not on its
            // own.
            return DatabaseHealth(name: name, state: .unknown, reason: "Kelp connects when you open it.")
        }
        if c.password == nil, c.database.passwordIn != nil {   // reading it would make macOS ask: only on opening it
            return DatabaseHealth(name: name, state: .unknown, reason: "Its password is read when you open it.")
        }
        let through = c.database.ssh.map { remotes.host($0, path: "/") } ?? remote
        if let through {
            // `ssh -O check`, up to 3 s: off the pool
            let connected: Bool
            do { connected = try await offloads.run { through.connection != nil } } catch { connected = false }
            if !connected {
                return DatabaseHealth(name: name, state: .unknown, reason: "\(through.host) isn't connected.")
            }
        }
        let said: String
        do {
            let near = try await offloads.run { [self] in try reach(c, worktreeId) }
            _ = try await DatabaseEngines.read(near, "SELECT 1", timeout: 3, off: offloads)
            return DatabaseHealth(name: name, state: .ok)
        } catch let failure as DatabaseFailure {
            said = failure.message
        } catch {
            said = "\(error)"
        }
        // It didn't answer: is it that compose isn't running it? (One that answers runs, whoever started it.)
        let stopped: Bool
        if let service = c.container {
            do {
                stopped = try await offloads.run {
                    Self.docker().flatMap { Self.container(service, docker: $0) } == nil
                }
            } catch { stopped = false }
        } else {
            stopped = false
        }
        if stopped, let service = c.container {
            return DatabaseHealth(
                name: name, state: .stopped, reason: "Its compose service \(service.name) isn't running.")
        }
        return DatabaseHealth(name: name, state: .down, reason: said)
    }

    func start(_ worktreeId: String, _ name: String) async throws {
        let target = try await offloads.run { [self] in try connection(worktreeId, name, agent: false) }
        guard let service = target.container, let docker = Self.docker() else {
            throw RPCError.invalidParams("\(name) isn't a compose service Kelp can start.")
        }
        let out = try await Subprocess.run(
            [docker, "compose", "-f", service.file, "up", "-d", service.name],
            cwd: (service.file as NSString).deletingLastPathComponent,
            env: ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()], timeLimit: 170)
        guard out.status == 0 else {
            let said = String(decoding: out.stderr, as: UTF8.self).split(whereSeparator: \.isNewline).last
            throw RPCError.invalidParams(said.map(String.init) ?? "docker compose couldn't start \(service.name).")
        }
        touch(worktreeId)
    }
}

extension DatabaseStatus: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [DatabaseHealth] {
        try await dbs.status(worktreeId, library: library ?? false)
    }
}

extension DatabaseStart: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> Done {
        try await dbs.start(worktreeId, name)
        return Done()
    }
}
