import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case path, socket(Int32), connect(Int32), bind(Int32), inUse
    public var description: String {
        switch self {
        case .path: "the socket's path is longer than macOS allows (104 bytes): set KELP_HOME to a shorter folder"
        case .socket(let code), .connect(let code), .bind(let code): String(cString: strerror(code))
        case .inUse: "another program answers on Kelp's socket"
        }
    }
}

public enum Unix {
    static func addr(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < cap else { throw SocketError.path }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        return address
    }

    /// `patience`: how long a full queue (a burst of clients while a new kelpd takes over, ECONNREFUSED / EAGAIN) is
    /// tried again before it counts as nobody answering.
    public static func connect(_ path: String, patience: TimeInterval) throws -> Int32 {
        let end = Date().addingTimeInterval(patience)
        while true {
            do { return try connect(path) } catch SocketError.connect(let code)
                where (code == ECONNREFUSED || code == EAGAIN) && Date() < end
            {
                usleep(50_000)
            }
        }
    }

    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }
        var address = try addr(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.connect(code)
        }
        noSigPipe(fd)
        return fd
    }

    /// Writing to a peer that hung up fails with EPIPE instead of killing the process (the app and the tests don't
    /// ignore SIGPIPE the way kelpd does; a daemon that went away mid-write must not take the app down with it).
    public static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A socket file someone still answers on is theirs: only a stale one (its owner gone) is replaced.
    public static func listen(_ path: String) throws -> Int32 {
        if let other = try? connect(path) {
            close(other)
            throw SocketError.inUse
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }
        var address = try addr(path)
        closeOffDirectory((path as NSString).deletingLastPathComponent)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.bind(code)
        }
        chmod(path, 0o600)   // the socket is the auth boundary locally
        return fd
    }

    /// Nobody else can reach the socket between bind and chmod (umask is process-wide, so not that): its folder is ours alone.
    /// A folder that isn't ours, or is shared (sticky, like /tmp), is left as it is; the socket's own mode still holds.
    private static func closeOffDirectory(_ dir: String) {
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & S_ISVTX == 0 else { return }
        chmod(dir, 0o700)
    }

    /// Whether the process on the other end of an accepted connection runs as this user (or root).
    /// The socket's own 0600 mode already says so; this holds even if someone loosens it.
    public static func peerIsUs(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid() || uid == 0
    }

    /// The program on the other end of a connection (`peerPID`'s, as it is now), resolved: who is asking.
    public static func peerExecutable(_ fd: Int32) -> String? {
        guard let pid = peerPID(fd) else { return nil }
        return executable(pid)
    }

    /// The pid of the process on the other end: the last one that sent on it (the one that connected, until another
    /// sharing the socket writes), as of this call. A program it exec'd since reads as that program.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0, len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 && pid > 0 ? pid : nil
    }

    /// A running process's program, resolved.
    public static func executable(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cBuffer: buf)).resolvingSymlinksInPath().path
    }

    /// Write all bytes, retrying on partial writes. Returns false if the peer is gone.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return true }   // nothing to write
            var off = 0
            while off < bytes.count {
                let written = Darwin.write(fd, base + off, bytes.count - off)
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN {   // full: wait until it can take more, rather than spin
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 5000) <= 0 { return false }   // nobody reading for 5 s: gone
                    continue
                }
                if written < 0 { return false }
                off += written
            }
            return true
        }
    }
}

extension String {
    /// The text a C call wrote into `buffer`, up to its NUL (`String(cString:)` on an array is deprecated).
    package init(cBuffer buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
