import Core
import Darwin
import Foundation
import Testing

@testable import Daemon

/// A socket of this process, listening or only bound, on a port the system picks.
private func socket(listening: Bool) throws -> (fd: Int32, port: Int) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &a) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
        }
    }
    try #require(bound)
    if listening { try #require(listen(fd, 1) == 0) }
    return (fd, Int(UInt16(bigEndian: a.sin_port)))
}

@Test func theKernelSaysWhichPortsAProcessListensOn() throws {
    let on = try socket(listening: true), off = try socket(listening: false)
    defer { close(off.fd) }   // `on` is closed below, once: closed twice, the second could take another's fd (a guarded one ends the process)
    let ports = SessionProcesses.listening(getpid())
    #expect(ports.contains(on.port))
    #expect(!ports.contains(off.port))   // bound, nobody can connect yet
    close(on.fd)
    #expect(!SessionProcesses.listening(getpid()).contains(on.port))
    #expect(SessionProcesses.listening(-1).isEmpty)   // a process that's gone
}

@Test func aHostsListenersAreReadFromSSAndTheFolderDecides() throws {
    // A stand-in ss with what Linux's prints. pid 1 runs in /, this test in the project; no process, no line from ss.
    let bin = tmp()
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    echo 'LISTEN 0 5 0.0.0.0:8000 0.0.0.0:* users:(("python3",pid=\(getpid()),fd=3))'
    echo 'LISTEN 0 511 [::1]:5173 [::]:* users:(("node",pid=1,fd=20))'
    echo 'LISTEN 0 128 127.0.0.1:22 0.0.0.0:*'
    """.write(to: bin.appendingPathComponent("ss"), atomically: true, encoding: .utf8)
    chmod(bin.appendingPathComponent("ss").path, 0o755)
    let here = FileManager.default.currentDirectoryPath
    let r = try Subprocess.run(
        ["/bin/sh", "-c", HostPorts.script(here)], cwd: NSHomeDirectory(),
        env: ["PATH": bin.path + ":/usr/bin:/bin:/usr/sbin"], timeLimit: 10)
    #expect(
        HostPorts.parse(String(decoding: r.stdout, as: UTF8.self)) == [
            HostPorts.Listener(port: 8000, pid: getpid(), command: "python3")
        ])
    #expect(
        HostPorts.parse("Welcome to the box\n\u{1E}8000 12 uvicorn worker\n") == [
            HostPorts.Listener(port: 8000, pid: 12, command: "uvicorn worker")
        ])
    #expect(HostPorts.parse("no ports here\n").isEmpty)
}

@Test func whatAPortForwardingMayName() throws {
    #expect(try Forwards.target("8000") == "localhost:8000")
    #expect(try Forwards.target(" db.internal:5432 ") == "db.internal:5432")
    #expect(throws: (any Error).self) { try Forwards.target("-oProxyCommand=x:1") }
    #expect(throws: (any Error).self) { try Forwards.target("a b:1") }
    #expect(Forwards.spec(8001, "localhost:8000") == "127.0.0.1:8001:localhost:8000")   // this Mac only
}

@Test func aServerSaysItsPortIsTaken() {
    func port(_ s: String) -> Int? {
        guard let m = LiveSession.busyRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else {
            return nil
        }
        return [1, 2].lazy.compactMap { Range(m.range(at: $0), in: s) }.first.flatMap { Int(s[$0]) }
    }
    #expect(port("Error: listen EADDRINUSE: address already in use :::3000") == 3000)
    #expect(port("Error: listen EADDRINUSE: address already in use 127.0.0.1:5173") == 5173)
    #expect(port("Port 3000 is already in use") == 3000)
    #expect(port("Address already in use - bind(2) for \"127.0.0.1\" port 3000 (Errno::EADDRINUSE)") == 3000)
    #expect(port("OSError: [Errno 48] Address already in use") == nil)   // says no port
    #expect(port("Local: http://localhost:3000/") == nil)
}

/// Against the ssh stand-in, which says every connection is alive and logs what the master is asked.
@Test func aHostsPortComesHereOverTheSharedConnection() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = try makeRepo()
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    #expect(try await c.call(PortsForward(worktreeId: w.id, port: 18999)).port == 18999)
    #expect(try await c.call(PortsForward(worktreeId: w.id, target: "22")).port == 10022)   // only root binds :22 here
    await #expect(throws: (any Error).self) { try await c.call(PortsForward(worktreeId: w.id)) }
    await #expect(throws: (any Error).self) {
        try await c.call(PortsForward(worktreeId: w.id, target: "-oProxyCommand=x:1"))
    }
    let log = {
        try String(contentsOfFile: (localSSH as NSString).deletingLastPathComponent + "/ssh.log", encoding: .utf8)
    }
    #expect(try log().contains("forward -L 127.0.0.1:18999:localhost:18999"))
    // Asked for by hand, it's listed though nothing there listens, and has no process to stop.
    let ports = try await c.call(PortsList(worktreeId: w.id))
    #expect(ports.first { $0.port == 22 }?.here == 10022 && ports.first { $0.port == 22 }?.pid == 0)
    _ = try await c.call(PortsUnforward(worktreeId: w.id, port: 22))
    #expect(try log().contains("cancel -L 127.0.0.1:10022:localhost:22"))
    #expect(try await c.call(PortsList(worktreeId: w.id)).contains { $0.port == 22 } == false)
    // This Mac's own projects forward nothing.
    let local = try await c.call("worktree.list", as: [Worktree].self).filter { $0.repoId != repo.id }
    if let l = local.first {
        await #expect(throws: (any Error).self) { try await c.call(PortsForward(worktreeId: l.id, port: 1)) }
    }
}

/// Forwardings changed from many threads at once (a prune beside a forward) are saved as they end up, not as an older copy.
@Test func portForwardingsAreSavedInTheOrderTheyChanged() throws {
    for _ in 0..<12 {   // a lost save is a race: one round finds it about a third of the time
        let store = try Store(), forwards = Forwards(store: store)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            forwards.change {
                $0.append(Forwards.Record(host: "box", target: "localhost:\(i)", here: i, worktree: "w", manual: true))
            }
        }
        let text = try store.uiState(prefix: "ports.forwards")["ports.forwards"]?.string ?? ""
        #expect(try JSONDecoder().decode([Forwards.Record].self, from: Data(text.utf8)).count == 400)
    }
}
