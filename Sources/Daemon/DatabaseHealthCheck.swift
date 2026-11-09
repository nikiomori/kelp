import Core
import Foundation

/// The panel's dots: each database tried once (SELECT 1, a few seconds at most), side by side. A server reached over
/// SSH, or a remote project's, is tried only through a connection that's open already: the panel never dials.
extension Databases {
    func status(_ worktreeId: String) async throws -> [DatabaseHealth] {
        let all = try await offloads.run { [self] in try connections(worktreeId) }
        let path = try store.worktree(worktreeId)?.path ?? ""
        let remote = remotes.of(path)
        return await withTaskGroup(of: (Int, DatabaseHealth).self) { group in
            for (index, c) in all.enumerated() {
                group.addTask { [self] in (index, await health(c, worktreeId, remote: remote)) }
            }
            var out: [(Int, DatabaseHealth)] = []
            for await one in group { out.append(one) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func health(_ c: DatabaseConnection, _ worktreeId: String, remote: RemoteHost?) async -> DatabaseHealth {
        let name = c.database.name
        if c.database.engine.isFile {
            let there = c.database.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return DatabaseHealth(name: name, state: there ? .ok : .down, reason: there ? nil : "The file isn't there.")
        }
        let through = c.database.ssh.map { remotes.host($0, path: "/") } ?? remote
        if let through, through.connection == nil {
            return DatabaseHealth(name: name, state: .unknown, reason: "\(through.host) isn't connected.")
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
            do { stopped = try await !offloads.run { Self.running(service) } } catch { stopped = false }
        } else {
            stopped = false
        }
        if stopped, let service = c.container {
            return DatabaseHealth(
                name: name, state: .stopped, reason: "Its compose service \(service.name) isn't running.")
        }
        return DatabaseHealth(name: name, state: .down, reason: said)
    }

    /// Whether compose runs the service now (`docker compose ps -q` names a container).
    static func running(_ service: ComposeService) -> Bool {
        guard let docker = docker() else { return false }
        let id = Subprocess.printed(
            [docker, "compose", "-f", service.file, "ps", "-q", service.name], path: "/usr/local/bin:/usr/bin:/bin",
            timeout: 10)
        return !(id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start(_ worktreeId: String, _ name: String) async throws {
        let c = try await offloads.run { [self] in try connection(worktreeId, name, agent: false) }
        guard let service = c.container, let docker = Self.docker() else {
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
    func handle(_ dbs: Databases) async throws -> [DatabaseHealth] { try await dbs.status(worktreeId) }
}

extension DatabaseStart: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> Done {
        try await dbs.start(worktreeId, name)
        return Done()
    }
}
