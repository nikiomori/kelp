import Core
import Foundation
import Testing
import os

@testable import Daemon

// What a usage probe and a database call leave behind once they end: no process, no terminal, no connection.

/// A usage probe that read the usage, and one that gave up (its agent said it failed), each leave no process of it (its
/// own child included) and no fd of its terminal open in kelpd.
@Test(.timeLimit(.minutes(1))) func aUsageProbeLeavesNothingBehind() async throws {
    let reads = "printf '❯ '; read line; printf '5%% used'"
    for (why, said) in [("it read the usage", reads), ("it gave up", "printf 'Error: not signed in'")] {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = { (name: String) in dir.appendingPathComponent(name).path }
        // Its tty and pids written first, then what it says; then it waits, as an agent does, with a child of its own,
        // both deaf to the hangup and SIGTERM (as Grok was): only the probe's SIGKILL ends them.
        let script =
            "trap '' HUP TERM; tty > \(file("tty")); echo $$ > \(file("pid")); sleep 30 & echo $! > \(file("child")); "
            + "while [ ! -e \(file("go")) ]; do sleep 0.05; done; \(said); sleep 30"
        let probe = AgentUsage.PlanProbe(
            agent: "claude", command: "claude", every: 600, ready: { $0.contains("❯") },
            shown: { $0.contains("% used") }, parse: { _ in [] })
        let ended = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            _ = AgentUsage.probe(probe, argv: ["/bin/bash", "-c", script], cwd: NSTemporaryDirectory())
            ended.withLock { $0 = true }
        }
        #expect(try await waitFor(5) { FileManager.default.fileExists(atPath: file("child")) }, "\(why)")
        let tty = try text(file("tty")), pid = try pidIn(file("pid")), child = try pidIn(file("child"))
        let open = terminals(named: tty)
        #expect(!open.isEmpty, "\(why): the probe's terminal is open in kelpd while it runs")
        FileManager.default.createFile(atPath: file("go"), contents: nil)
        #expect(try await waitFor(30) { ended.withLock { $0 } }, "\(why)")
        #expect(try await waitFor(5) { kill(pid, 0) != 0 && kill(child, 0) != 0 }, "\(why): no process of it left")
        #expect(
            try await waitFor(5) { terminals(named: tty).isDisjoint(with: open) },
            "\(why): its terminal's fds are closed")
    }
}

/// A Postgres or MySQL connection whose call runs past its time is closed (`DatabaseWire.within`): the server sees it
/// go, and the call fails then, saying so, not when the server answers (this one never does).
@Test(.timeLimit(.minutes(1))) func aDatabaseCallPastItsTimeClosesItsConnection() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for engine in [DatabaseInfo.Engine.postgres, .mysql] { group.addTask { try await callPastItsTime(engine) } }
        try await group.waitForAll()
    }
}

private func callPastItsTime(_ engine: DatabaseInfo.Engine) async throws {
    let server = try SilentServer(engine)
    var db = DatabaseInfo(name: "slow", engine: engine, host: "127.0.0.1", port: server.port, database: "d", user: "u")
    db.ssl = "disable"
    let conn = DatabaseConnection(database: db)
    // Its whole time is `timeout + 10`: 10 s. Waited for 25 s at most: a call that never ends fails here, not as a hang.
    let said = await firstOf(seconds: 25, otherwise: "no answer after 25 s") {
        do {
            _ =
                engine == .postgres
                ? try await PostgresWire.read(conn, "SELECT 1", timeout: 0)
                : try await MySQLWire.read(conn, "SELECT 1", timeout: 0)
            return "an answer"
        } catch { return (error as? DatabaseFailure)?.message ?? "\(error)" }
    }
    #expect(said.contains("No answer from slow"), "\(engine): \(said)")
    #expect(server.loggedIn, "\(engine): it was past the login, in its query")
    #expect(try await waitFor(5) { server.closed }, "\(engine): the server saw its connection closed")
}

/// What `work` says, or `otherwise` once `seconds` pass first: the work is left running, not awaited (a task group
/// would wait for it).
private func firstOf(
    seconds: Double, otherwise: String, _ work: @escaping @Sendable () async -> String
) async -> String {
    await withCheckedContinuation { (said: CheckedContinuation<String, Never>) in
        let told = OSAllocatedUnfairLock(initialState: false)
        let tell = { @Sendable (text: String) in
            if told.withLock({ was in
                defer { was = true }
                return !was
            }) {
                said.resume(returning: text)
            }
        }
        Task { tell(await work()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { tell(otherwise) }
    }
}

private func text(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func pidIn(_ path: String) throws -> pid_t { try #require(pid_t(try text(path))) }

/// The fds of this process that are a terminal's primary side named `tty` (/dev/ttys012).
private func terminals(named tty: String) -> Set<Int32> {
    var name = [CChar](repeating: 0, count: 128)
    return Set(
        (0..<getdtablesize()).filter { fd in
            fcntl(fd, F_GETFD) != -1 && ptsname_r(fd, &name, name.count) == 0
                && String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == tty
        })
}

/// A database server on the loopback that takes one connection, lets it log in (Postgres's AuthenticationOk and
/// ReadyForQuery, MySQL's greeting and OK), then reads its query and never answers; `closed` once the client closes.
private final class SilentServer: Sendable {
    let port: Int
    private let state = OSAllocatedUnfairLock(initialState: (loggedIn: false, closed: false))
    var loggedIn: Bool { state.withLock { $0.loggedIn } }
    var closed: Bool { state.withLock { $0.closed } }

    init(_ engine: DatabaseInfo.Engine) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard bound else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        let state = state
        Thread.detachNewThread {
            let client = accept(fd, nil, nil)
            close(fd)
            if engine == .postgres { Self.postgresLogin(client) } else { Self.mysqlLogin(client) }
            state.withLock { $0.loggedIn = true }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(client, &buffer, buffer.count) > 0 {}   // its query, never answered: until it's closed
            state.withLock { $0.closed = true }
            close(client)
        }
    }

    private static func postgresLogin(_ fd: Int32) {
        let length = bytes(fd, 4).reduce(0) { $0 << 8 | Int($1) }
        _ = bytes(fd, length - 4)   // the startup message
        // AuthenticationOk, BackendKeyData, ReadyForQuery (idle)
        send(
            fd, [0x52, 0, 0, 0, 8, 0, 0, 0, 0] + [0x4B, 0, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0, 2] + [0x5A, 0, 0, 0, 5, 0x49])
    }

    private static func mysqlLogin(_ fd: Int32) {
        // Protocol 4.1, secure connection, plugin auth (and long password, a database, transactions).
        let capabilities: UInt32 = 0x1 | 0x8 | 0x200 | 0x2000 | 0x8000 | 0x8_0000
        var greeting: [UInt8] = [0x0A] + Array("8.0.36".utf8) + [0, 1, 0, 0, 0] + Array(repeating: 0x61, count: 8) + [0]
        greeting += [UInt8(capabilities & 0xFF), UInt8(capabilities >> 8 & 0xFF), 0x21, 0x02, 0x00]
        greeting +=
            [UInt8(capabilities >> 16 & 0xFF), UInt8(capabilities >> 24 & 0xFF), 21] + Array(repeating: 0, count: 10)
        greeting += Array(repeating: 0x62, count: 12) + [0] + Array("mysql_native_password".utf8) + [0]
        send(fd, [UInt8(greeting.count & 0xFF), UInt8(greeting.count >> 8 & 0xFF), 0, 0] + greeting)
        let header = bytes(fd, 4)
        _ = bytes(fd, Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16)   // its login
        send(fd, [7, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0])   // OK
    }

    private static func bytes(_ fd: Int32, _ count: Int) -> [UInt8] {
        var out = [UInt8](), buffer = [UInt8](repeating: 0, count: max(count, 1))
        while out.count < count {
            let got = read(fd, &buffer, count - out.count)
            guard got > 0 else { break }
            out += buffer[0..<got]
        }
        return out + [UInt8](repeating: 0, count: count - out.count)
    }

    private static func send(_ fd: Int32, _ data: [UInt8]) {
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
