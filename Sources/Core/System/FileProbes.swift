import Foundation
import os

/// Reads of things that may not be there, such as a config file, a cache or a folder of extensions. A missing file (or
/// a file where a folder was expected) is a normal answer, nil or empty, and isn't logged. Any other failure (no
/// permission, a folder where a file was expected) gives the caller the same answer but is logged, where a bare `try?`
/// would have hidden it.
private let log = Logger.kelp("files")

private func noSuchFile(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
        return true
    }
    if ns.domain == NSPOSIXErrorDomain, [ENOENT, ENOTDIR].contains(Int32(ns.code)) { return true }   // ENOTDIR: a file
    return (ns.userInfo[NSUnderlyingErrorKey] as? Error).map(noSuchFile) ?? false
}

private func probe<T>(_ what: String, _ path: String, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        if !noSuchFile(error) { log.error("\(what, privacy: .public) \(path): \(error)") }
        return nil
    }
}

extension Data {
    /// Reads the file's bytes, or returns nil when there is no such file.
    public init?(contentsIfAny url: URL, options: Data.ReadingOptions = []) {
        guard let data = probe("reading", url.path, { try Data(contentsOf: url, options: options) }) else { return nil }
        self = data
    }

    /// Reads up to `count` bytes from the start of the file (or from `offset`), or returns nil when there is no such
    /// file.
    public init?(head count: Int, of url: URL, from offset: UInt64 = 0) {
        let data = probe("reading", url.path) { () throws -> Data in
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeQuietly() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
        guard let data else { return nil }
        self = data
    }

    /// Reads the file's last `count` bytes (all of a smaller file), or returns nil when there is no such file.
    public init?(tail count: Int, of url: URL) {
        let data = probe("reading", url.path) { () throws -> Data in
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeQuietly() }
            return try handle.tail(count)
        }
        guard let data else { return nil }
        self = data
    }
}

extension FileHandle {
    /// Returns the last `count` bytes of the file, whatever the handle's position was.
    public func tail(_ count: Int) throws -> Data {
        let size = try seekToEnd()
        try seek(toOffset: size > UInt64(count) ? size - UInt64(count) : 0)
        return try readToEnd() ?? Data()
    }

    /// Closes a handle that was only read from. A failed close loses nothing, so it is only logged.
    public func closeQuietly() {
        do { try close() } catch { log.error("closing a file: \(error)") }
    }
}

extension String {
    /// Reads the file's text as UTF-8, or returns nil when there is no such file or it isn't text.
    public init?(contentsIfAny url: URL) {
        guard let text = probe("reading", url.path, { try String(contentsOf: url, encoding: .utf8) }) else {
            return nil
        }
        self = text
    }
}

extension FileManager {
    /// Returns the items in the folder, or none when there is no such folder.
    public func items(in folder: URL) -> [URL] {
        probe("listing", folder.path) { try contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) } ?? []
    }

    /// Returns the names of the items in the folder, or none when there is no such folder.
    public func names(in folder: String) -> [String] {
        probe("listing", folder) { try contentsOfDirectory(atPath: folder) } ?? []
    }

    /// Returns when the file (or the file a link points at) was last changed, or nil when there is no such file.
    public func modified(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Removes the file or folder if it is there. A failure to remove it is logged.
    public func removeIfAny(_ url: URL) {
        _ = probe("removing", url.path) { try removeItem(at: url) }
    }
}

/// Remembers what was last read from each file, and returns it again while the file's size and last write time stay
/// the same. So a transcript's tail read every few seconds costs only a stat while nothing is written. The stat comes
/// before the read, so a write during a read is read again next time. A file that isn't a plain file (gone, a link) is
/// read every time.
public final class StatMemo<Value: Sendable>: Sendable {
    private let memo = OSAllocatedUnfairLock<[String: (size: off_t, sec: Int, nsec: Int, value: Value)]>(
        initialState: [:])
    private let limit: Int

    /// `limit` is how many files are remembered. Past it, all of them are forgotten, because a host's tails come as new
    /// temporary files.
    public init(limit: Int = 64) { self.limit = limit }

    public func value(_ path: String, _ read: () -> Value) -> Value {
        guard let stat = Artifacts.fileStat(path) else { return read() }
        let size = stat.size, sec = stat.mtime.tv_sec, nsec = stat.mtime.tv_nsec
        if let hit = memo.withLock({ $0[path] }), hit.size == size, hit.sec == sec, hit.nsec == nsec {
            return hit.value
        }
        let value = read()
        memo.withLock { memo in
            if memo.count >= limit { memo.removeAll() }
            memo[path] = (size, sec, nsec, value)
        }
        return value
    }
}
