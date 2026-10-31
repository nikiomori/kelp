import Foundation
import Core

/// A session's status changes and the hooks it heard, a line each, beside its history log: what `kelp why` can't tell from
/// the status of now, once a row has read wrong. The file goes on through a pause and a new kelpd.
/// Limit: only what reached the daemon. A hook that never did leaves no line, and what the app made of a change isn't here.
struct StatusTrail: Sendable {
    /// Past this the file keeps its newer half: some thousands of lines.
    static let limit = 256 << 10
    private static let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    let url: URL
    private let disk = DispatchQueue(label: "kelp.session.trail", qos: .utility)
    init(history: URL, session: String) { url = history.appendingPathComponent("\(session).trail") }

    /// Queued, so it's safe under the session's lock and lines stay in the order they were added. `up` is the clock that
    /// stands still while the Mac sleeps: a gap in the time but not in `up` was sleep.
    func add(_ what: String) {
        let now = Date(), up = Int(ProcessInfo.processInfo.systemUptime)
        disk.async { [url] in
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }   // unlogged: a full disk would flood the log
            defer { close(fd) }
            Unix.writeAll(fd, Data("\(now.formatted(Self.time))  up \(up)  \(what)\n".utf8))
            if lseek(fd, 0, SEEK_END) > off_t(Self.limit) { Self.trim(url) }
        }
    }

    /// Everything so far, oldest first; empty when nothing was written.
    func read() -> String {
        disk.sync {}   // what's still on its way
        return Data(tailOf: url, bytes: 2 * Self.limit).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func trim(_ url: URL) {
        guard let tail = Data(tailOf: url, bytes: limit / 2), let cut = tail.firstIndex(of: 0x0A) else { return }
        Log.session.attempt("trimming \(url.lastPathComponent)") { try tail[tail.index(after: cut)...].write(to: url, options: .atomic) }
    }
}
