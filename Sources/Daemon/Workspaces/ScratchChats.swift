import Core
import Foundation
import GitKit

/// Chats outside any project ("No Project" in the sidebar): the scratch folder in Kelp's home, with each agent in a folder
/// of its own named by its day, so one task's files don't land among another's and an agent's resume list is its own.
/// Rules for all of them go in the scratch folder's own CLAUDE.md / AGENTS.md: agents read those from the folder above.
struct ScratchChats {
    let folder: URL
    init(root: URL) { folder = root.appendingPathComponent("scratch") }

    private var real: String { Paths.real(folder.path) ?? folder.path }

    /// Whether `path` is the scratch folder itself (its workspace's), where a new agent gets a folder of its own.
    func holds(_ path: String) -> Bool { (Paths.real(path) ?? path) == real }

    /// A new empty folder for a chat: 2026-11-04-1, -2… the first free one that day.
    func newChat(now: Date = Date()) throws -> String {
        try Paths.ensure(folder)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        var number = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(day)-\(number)").path) {
            number += 1
        }
        let dir = folder.appendingPathComponent("\(day)-\(number)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return Paths.real(dir.path) ?? dir.path
    }

    /// A chat folder Kelp made with nothing in it yet: an agent's "trust this folder?" has nothing there to guard.
    func isFresh(_ cwd: String) -> Bool {
        let path = Paths.real(cwd) ?? cwd
        return (path as NSString).deletingLastPathComponent == real && Self.isEmpty(path)
    }

    /// Whether `cwd` is a chat's own folder, there or gone.
    func isChat(_ cwd: String) -> Bool {
        let path = Paths.real(cwd) ?? cwd
        return [real, folder.path].contains((path as NSString).deletingLastPathComponent)
    }

    /// Chat folders left empty that no session works in any more go (ended records are pruned a week after the end; a chat
    /// resumed later gets its folder again). Anything with a file in it stays: it's someone's result. A day old at least: a
    /// new chat's folder is made just before its record is saved.
    func sweep(keeping cwds: Set<String>, now: Date = Date()) {
        let used = Set(cwds.map { Paths.real($0) ?? $0 })
        let fm = FileManager.default
        for name in Self.names(real) {
            let path = real + "/" + name
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &dir), dir.boolValue, !used.contains(path),
                Self.isEmpty(path),
                let made = Log.store.attempt(
                    "reading when \(name) was made", { try fm.attributesOfItem(atPath: path)[.creationDate] as? Date })
                    ?? nil,
                made < now - 86400
            else { continue }
            Log.store.attempt("removing the empty chat folder \(name)") { try fm.removeItem(atPath: path) }
        }
    }

    /// Homes from before: scratch was a git repo Kelp made. One that never got a commit or a file goes back to a plain folder.
    func dropUnusedRepo(remotes: Remotes) {
        let fm = FileManager.default
        // `rev-parse --verify -q` prints nothing and exits 1 when there's no commit.
        guard fm.fileExists(atPath: folder.appendingPathComponent(".git").path),
            Self.names(folder.path).allSatisfy({ [".git", ".DS_Store"].contains($0) }),
            Log.store.attempt(
                "reading scratch's git",
                {
                    try Git.run(
                        ["rev-parse", "--verify", "-q", "HEAD"], cwd: folder.path, ok: [0, 1], remotes: remotes)
                })?.isEmpty == true
        else { return }
        Log.store.attempt("removing scratch's empty git repo") {
            try fm.removeItem(at: folder.appendingPathComponent(".git"))
        }
    }

    private static func isEmpty(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && names(path).allSatisfy { $0 == ".DS_Store" }
    }

    /// What's right in a folder (none when it isn't one).
    private static func names(_ path: String) -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
    }
}
