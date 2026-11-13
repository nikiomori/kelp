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
        // New files git doesn't track yet: their lines are all additions (small text files only). A host's are counted there.
        if let host = remotes.of(cwd) {
            let out = try host.run("cd \(RemoteHost.cdArg(host.path)) && " + untrackedLines, timeLimit: 60)
            for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let count = Int(fields[0].trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                stats.added[LineStats.kind(String(fields[1])), default: 0] += count
            }
            return stats
        }
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

    /// sh, in a repository: "lines\tpath" for each of its first 500 new files that is text under 1 MB (paths with a line
    /// break in them are skipped).
    static let untrackedLines =
        #"git -c core.quotePath=false ls-files --others --exclude-standard | head -n 500 | while IFS= read -r f; do "#
        + #"[ -f "$f" ] && [ "$(wc -c < "$f")" -lt 1000000 ] && grep -Iq . "$f" && printf '%s\t%s\n' "$(wc -l < "$f")" "$f"; "#
        + "done; exit 0"
}
