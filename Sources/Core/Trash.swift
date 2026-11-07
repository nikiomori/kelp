import Foundation

/// The Trash, where Kelp puts what it removes from the user's disk: put back with the Finder's "Put Back" or ⌘Z.
/// `KELP_TRASH` (the tests') is a folder in its place, so no test leaves anything in the user's own.
public enum Trash {
    /// Where `url` went.
    @discardableResult
    public static func move(_ url: URL) throws -> URL {
        if let dir = ProcessInfo.processInfo.environment["KELP_TRASH"] {
            let to = URL(fileURLWithPath: dir).appendingPathComponent(UUID().uuidString).appendingPathComponent(
                url.lastPathComponent)
            try FileManager.default.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return (out as URL?) ?? url
    }
}
