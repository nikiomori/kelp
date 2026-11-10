import Core
import Foundation

extension Git {
    public static func lineStats(_ cwd: String, remotes: Remotes) throws -> LineStats {
        var stats = LineStats()
        // No commit yet: there's no HEAD, the staged files are all there is.
        let tracked =
            try (try? run(["diff", "HEAD", "--numstat", "--no-renames", "-z"], cwd: cwd, remotes: remotes))
            ?? run(["diff", "--cached", "--numstat", "--no-renames", "-z"], cwd: cwd, remotes: remotes)
        for line in tracked.split(separator: "\0") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            // "-" = binary
            guard fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]) else { continue }
            let kind = LineStats.kind(String(fields[2]))
            stats.added[kind, default: 0] += added
            stats.removed[kind, default: 0] += removed
        }
        // New files git doesn't track yet: their lines are all additions (small text files only).
        for path in try run(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd, remotes: remotes).split(
            separator: "\0"
        ).prefix(500) {
            let url = URL(fileURLWithPath: cwd).appendingPathComponent(String(path))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
                let data = Data(contentsIfAny: url), !data.contains(0)
            else { continue }
            stats.added[LineStats.kind(String(path)), default: 0] += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return stats
    }
}
