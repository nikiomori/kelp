import Core
import Foundation

extension Git {
    public static func lineStats(_ cwd: String, remotes: Remotes = .none) throws -> LineStats {
        var s = LineStats()
        // No commit yet: there's no HEAD, the staged files are all there is.
        let tracked =
            try (try? run(["diff", "HEAD", "--numstat", "--no-renames", "-z"], cwd: cwd, remotes: remotes))
            ?? run(["diff", "--cached", "--numstat", "--no-renames", "-z"], cwd: cwd, remotes: remotes)
        for line in tracked.split(separator: "\0") {
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3, let a = Int(f[0]), let d = Int(f[1]) else { continue }   // "-" = binary
            let k = LineStats.kind(String(f[2]))
            s.added[k, default: 0] += a
            s.removed[k, default: 0] += d
        }
        // New files git doesn't track yet: their lines are all additions (small text files only).
        for p in try run(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd, remotes: remotes).split(
            separator: "\0"
        ).prefix(500) {
            let url = URL(fileURLWithPath: cwd).appendingPathComponent(String(p))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
                let d = try? Data(contentsOf: url), !d.contains(0)
            else { continue }
            s.added[LineStats.kind(String(p)), default: 0] += d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return s
    }
}
