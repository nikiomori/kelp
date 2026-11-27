import Core
import Foundation
import KelpKit

/// Writes several files, each over the version that was read, and undoes them all as one. A write that's refused,
/// because the file changed or went away since it was read, counts as nothing written. It never counts as done, and
/// Undo never puts it back.
@MainActor
enum FileBatch {
    /// One file that was written, with what it held before and the version that went in, so Undo can put it back.
    struct Done { let path: String, old: String, stamp: FileStamp }

    /// Writes one file and returns the version that went in, or nil when the write was refused or failed. A failure
    /// shows its own banner.
    static func write(_ path: String, _ text: String, over base: FileStamp, app: AppModel) async -> FileStamp? {
        await app.call(FilesWrite(path: path, text: text, base: base))?.stamp
    }

    /// Writes all the files or none. On the first refusal, the files already written go back, and the result names the
    /// refused file.
    static func writeAll(_ files: [(path: String, old: String, new: String, base: FileStamp)], app: AppModel) async
        -> Result<[Done], Refused>
    {
        var done: [Done] = []
        for file in files {
            guard let stamp = await write(file.path, file.new, over: file.base, app: app) else {
                let stuck = await undo(done, app: app)
                return .failure(Refused(path: file.path, stuck: stuck))
            }
            done.append(Done(path: file.path, old: file.old, stamp: stamp))
        }
        return .success(done)
    }

    /// Puts each file back over the version that was written. Returns the files that changed again since then, which
    /// keep what they hold now.
    static func undo(_ done: [Done], app: AppModel) async -> [String] {
        var stuck: [String] = []
        for change in done.reversed() where await write(change.path, change.old, over: change.stamp, app: app) == nil {
            stuck.append(change.path)
        }
        return stuck
    }

    /// Runs Undo from a banner, and says which files couldn't go back.
    static func undoSaying(_ done: [Done], app: AppModel) async {
        let stuck = await undo(done, app: app)
        if !stuck.isEmpty {
            Banner.show(String(localized: "Changed again since, so kept as it is now: \(names(stuck))."), style: .error)
        }
    }

    struct Refused: Error { let path: String, stuck: [String] }

    static func names(_ paths: [String]) -> String {
        paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }
}
