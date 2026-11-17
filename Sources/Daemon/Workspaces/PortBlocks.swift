import Foundation

/// Gives each project folder its own block of ten ports, so two copies of an app can run side by side. Every session
/// started in the folder gets `KELP_PORT`, the first of the ten, and the nine after it are the folder's too.
/// `.kelp.yaml` commands use `$KELP_PORT` or `$((KELP_PORT+1))`, as a shell does.
/// A folder's block comes from its path, so it is the same on every run. When two folders land on one block, they are
/// told apart in path order.
/// Limit: a folder added later whose path sorts first takes the block when it collides with another folder's, and the
/// other folder moves. Only new sessions see the move.
enum PortBlocks {
    /// Ports 20000–48999. They sit below macOS's ephemeral ports (49152 and up), which outgoing connections take as
    /// their source ports.
    static let first = 20_000, size = 10, count = 2_900

    /// Returns the first port of the block for `folder`, given `folders`, which is every project folder Kelp knows.
    static func port(for folder: String, among folders: [String]) -> Int {
        var taken = Set<Int>()
        for other in Set(folders + [folder]).sorted() {
            var slot = start(other)
            while taken.contains(slot) { slot = (slot + 1) % count }
            if other == folder { return first + slot * size }
            taken.insert(slot)
        }
        return first + start(folder) * size
    }

    /// Returns a slot from the FNV-1a hash of the path, because Swift's own hash changes from run to run.
    private static func start(_ path: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(count))
    }
}
