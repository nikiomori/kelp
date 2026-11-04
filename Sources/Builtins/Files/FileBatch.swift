import Core
import Foundation
import KelpKit

/// Writes to several files, each over the version read, and their one Undo. A write that's refused (the file changed or
/// went since it was read) counts as nothing written: never as done, never as something Undo puts back.
@MainActor
enum FileBatch {
    /// A file written: what it held before and the version that went in, for Undo.
    struct Done { let path: String, old: String, stamp: FileStamp }

    /// One write → the version that went in, or nil when it was refused or failed (a failure has its banner).
    static func write(_ path: String, _ text: String, over base: FileStamp, app: AppModel) async -> FileStamp? {
        await app.call(FilesWrite(path: path, text: text, base: base))?.stamp
    }

    /// All or none: on the first refusal what was written goes back, and the file refused is the answer.
    static func writeAll(_ files: [(path: String, old: String, new: String, base: FileStamp)], app: AppModel) async -> Result<[Done], Refused> {
        var done: [Done] = []
        for f in files {
            guard let stamp = await write(f.path, f.new, over: f.base, app: app) else {
                let stuck = await undo(done, app: app)
                return .failure(Refused(path: f.path, stuck: stuck))
            }
            done.append(Done(path: f.path, old: f.old, stamp: stamp))
        }
        return .success(done)
    }

    /// Puts each back over the version written → the files that changed again since, which keep what they have now.
    static func undo(_ done: [Done], app: AppModel) async -> [String] {
        var stuck: [String] = []
        for d in done.reversed() where await write(d.path, d.old, over: d.stamp, app: app) == nil { stuck.append(d.path) }
        return stuck
    }

    /// Undo, from a banner: what couldn't go back is said.
    static func undoSaying(_ done: [Done], app: AppModel) async {
        let stuck = await undo(done, app: app)
        if !stuck.isEmpty { Banner.show(String(localized: "Changed again since, so kept as it is now: \(names(stuck))."), style: .error) }
    }

    struct Refused: Error { let path: String, stuck: [String] }

    static func names(_ paths: [String]) -> String { paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") }
}
