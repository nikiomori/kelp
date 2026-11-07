import Foundation

/// Each project folder's own ten ports, so two copies of an app run side by side: `KELP_PORT` (and the nine after it) in
/// every session started there; `.kelp.yaml` commands use `$KELP_PORT` or `$((KELP_PORT+1))`, as a shell does.
/// A folder's block comes from its path, the same on every run; two that land on one block are told apart in path order.
/// Limit: a folder added later whose path sorts first can move another's block when they collide (new sessions only).
public enum PortBlocks {
    /// 20000–48999: below macOS's ephemeral ports (49152 and up), where outgoing connections take their source ports.
    public static let first = 20_000, size = 10, count = 2_900

    /// The first port of `folder`'s block, among `folders` (every project folder Kelp knows).
    public static func port(for folder: String, among folders: [String]) -> Int {
        var taken = Set<Int>()
        for other in Set(folders + [folder]).sorted() {
            var slot = start(other)
            while taken.contains(slot) { slot = (slot + 1) % count }
            if other == folder { return first + slot * size }
            taken.insert(slot)
        }
        return first + start(folder) * size
    }

    /// FNV-1a of the path: Swift's own hash changes from run to run.
    private static func start(_ path: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(count))
    }
}
