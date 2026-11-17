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

    /// `patience` is how long to keep retrying a full queue (ECONNREFUSED or EAGAIN, from a burst of clients while a
    /// new kelpd takes over) before it counts as nobody answering.
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

    /// Makes writing to a peer that hung up fail with EPIPE instead of killing the process. The app and the tests don't
    /// ignore SIGPIPE the way kelpd does, and a daemon that went away mid-write must not take the app down with it.
    public static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Listens on `path`. A socket file that something still answers on belongs to that process, so only a stale file
    /// (whose owner is gone) is replaced.
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
        chmod(path, 0o600)   // The socket is the local auth boundary.
        return fd
    }

    /// Makes the socket's folder ours alone, so nobody else can reach the socket between bind and chmod. umask can't do
    /// it, because umask is process-wide. A folder that isn't ours, or is shared (sticky, like /tmp), is left as it is,
    /// and the socket's own mode still holds.
    private static func closeOffDirectory(_ dir: String) {
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & S_ISVTX == 0 else { return }
        chmod(dir, 0o700)
    }

    /// Whether the process on the other end of an accepted connection runs as this user (or root).
    /// The socket's own 0600 mode already ensures that, and this check holds even if someone loosens the mode.
    public static func peerIsUs(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid() || uid == 0
    }

    /// Returns the resolved path of the program on the other end of a connection (the program of `peerPID` as it is
    /// now), which says who is asking.
    public static func peerExecutable(_ fd: Int32) -> String? {
        guard let pid = peerPID(fd) else { return nil }
        return executable(pid)
    }

    /// Returns the pid of the process on the other end, as of this call. That is the last process that sent on the
    /// socket: the one that connected, until another process sharing the socket writes. If that process has exec'd a
    /// new program since, the pid reads as that program.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0, len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 && pid > 0 ? pid : nil
    }

    /// Returns the resolved path of a running process's program.
    public static func executable(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cBuffer: buf)).resolvingSymlinksInPath().path
    }

    /// Writes all bytes, retrying on partial writes. Returns false if the peer is gone, meaning it took nothing for
    /// `wait` seconds.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data, wait: TimeInterval = 5) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return true }   // Nothing to write.
            var off = 0
            while off < bytes.count {
                let written = Darwin.write(fd, base + off, bytes.count - off)
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN {   // The socket is full: wait for room rather than spin.
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, Int32(wait * 1000)) <= 0 { return false }   // Nobody read for that long.
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
    /// Reads the text a C call wrote into `buffer`, up to its NUL, because `String(cString:)` on an array is
    /// deprecated.
    package init(cBuffer buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
