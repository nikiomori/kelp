import Core
import Foundation
import os

extension Git {
    /// `untracked`: the new files a status just listed (`git status -uall`'s "?" entries), so they aren't listed again.
    public static func lineStats(_ cwd: String, untracked: [String]? = nil, remotes: Remotes) throws -> LineStats {
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
        let paths =
            try untracked
            ?? run(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd, remotes: remotes).split(
                separator: "\0"
            ).map(String.init)
        for path in paths.prefix(500) {
            guard let lines = lineCount(URL(fileURLWithPath: cwd).appendingPathComponent(path)) else { continue }
            stats.added[LineStats.kind(path), default: 0] += lines
        }
        return stats
    }

    /// A text file's lines under 1 MB (nil: bigger, binary or gone), read again only when its size or date moved: an
    /// agent writing one file doesn't have every other new file read on each change.
    static func lineCount(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, size < 1_000_000
        else { return nil }
        let stamp = LineCount(size: size, date: values.contentModificationDate)
        if let known = lineCounts.withLock({ $0[url.path] }), known.stamp == stamp { return known.lines }
        let lines = Data(contentsIfAny: url).flatMap { data in
            data.contains(0) ? nil : data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        lineCounts.withLock {
            if $0.count >= 5_000 { $0.removeAll() }   // Limit: 5,000 files remembered, then forgotten at once
            $0[url.path] = (stamp, lines)
        }
        return lines
    }

    private struct LineCount: Equatable {
        var size: Int, date: Date?
    }
    private static let lineCounts = OSAllocatedUnfairLock<[String: (stamp: LineCount, lines: Int?)]>(initialState: [:])

    /// sh, in a repository: "lines\tpath" for each of its first 500 new files that is text under 1 MB (paths with a line
    /// break in them are skipped).
    static let untrackedLines =
        #"git -c core.quotePath=false ls-files --others --exclude-standard | head -n 500 | while IFS= read -r f; do "#
        + #"[ -f "$f" ] && [ "$(wc -c < "$f")" -lt 1000000 ] && grep -Iq . "$f" && printf '%s\t%s\n' "$(wc -l < "$f")" "$f"; "#
        + "done; exit 0"
}
