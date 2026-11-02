import Darwin
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
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
    }
    try #require(bound)
    if listening { try #require(listen(fd, 1) == 0) }
    return (fd, Int(UInt16(bigEndian: a.sin_port)))
}

@Test func theKernelSaysWhichPortsAProcessListensOn() throws {
    let on = try socket(listening: true), off = try socket(listening: false)
    defer { close(on.fd); close(off.fd) }
    let ports = Sessions.listening(getpid())
    #expect(ports.contains(on.port))
    #expect(!ports.contains(off.port))   // bound, nobody can connect yet
    close(on.fd)
    #expect(!Sessions.listening(getpid()).contains(on.port))
    #expect(Sessions.listening(-1).isEmpty)   // a process that's gone
}
