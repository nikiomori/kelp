import Foundation
import os

/// Reads of what may not be there (a config file, a cache, a folder of extensions): no file (or a file where a folder
/// was looked for) is an answer, nil or none, and said nowhere. Any other failure (no permission, a folder where a file
/// was expected) is the same answer to the caller, but logged, where a bare `try?` would have hidden it.
private let log = Logger.kelp("files")

private func noSuchFile(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
        return true
    }
    if ns.domain == NSPOSIXErrorDomain, [ENOENT, ENOTDIR].contains(Int32(ns.code)) { return true }   // or a file there
    return (ns.userInfo[NSUnderlyingErrorKey] as? Error).map(noSuchFile) ?? false
}

private func probe<T>(_ what: String, _ path: String, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        if !noSuchFile(error) { log.error("\(what, privacy: .public) \(path): \(error)") }
        return nil
    }
}

extension Data {
    /// The file's bytes, nil when there's no such file.
    public init?(contentsIfAny url: URL, options: Data.ReadingOptions = []) {
        guard let data = probe("reading", url.path, { try Data(contentsOf: url, options: options) }) else { return nil }
        self = data
    }

    /// Up to `count` bytes from where the file starts (or from `offset`), nil when there's no such file.
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

    /// The file's last `count` bytes (all of a smaller one), nil when there's no such file.
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
    /// The last `count` bytes, from wherever the handle was.
    public func tail(_ count: Int) throws -> Data {
        let size = try seekToEnd()
        try seek(toOffset: size > UInt64(count) ? size - UInt64(count) : 0)
        return try readToEnd() ?? Data()
    }

    /// Closed, for a handle only read from: a failed close loses nothing, so it's only logged.
    public func closeQuietly() {
        do { try close() } catch { log.error("closing a file: \(error)") }
    }
}

extension String {
    /// The file's text (UTF-8), nil when there's no such file or it isn't text.
    public init?(contentsIfAny url: URL) {
        guard let text = probe("reading", url.path, { try String(contentsOf: url, encoding: .utf8) }) else {
            return nil
        }
        self = text
    }
}

extension FileManager {
    /// What the folder holds, none when there's no such folder.
    public func items(in folder: URL) -> [URL] {
        probe("listing", folder.path) { try contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) } ?? []
    }

    /// The names of what the folder holds, none when there's no such folder.
    public func names(in folder: String) -> [String] {
        probe("listing", folder) { try contentsOfDirectory(atPath: folder) } ?? []
    }

    /// The file or folder gone, whether or not it was there: what can't be removed is logged.
    public func removeIfAny(_ url: URL) {
        _ = probe("removing", url.path) { try removeItem(at: url) }
    }
}
