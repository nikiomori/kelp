import Core
import Foundation
import GitKit
import os

/// Finds the GitHub repository that a remote project's origin names. gh runs on this Mac, with the user's own gh login,
/// on that repository (`GH_REPO`). It doesn't run in the project's folder here, which holds only a marker, because gh's
/// git would walk up from it into whatever repository holds Kelp's home. The origin is read on the host at most once in
/// ten minutes.
enum HostRepo {
    private static let known = OSAllocatedUnfairLock<[String: (repo: String?, at: Date)]>(initialState: [:])
    private static let reading = OSAllocatedUnfairLock<[String: NSLock]>(initialState: [:])

    /// Returns the remote project that `cwd` is in (found by the home it's under, `<home>/remote/…`), and how its host
    /// is reached.
    static func project(_ cwd: String) -> (folder: String, remotes: Remotes)? {
        guard let home = cwd.range(of: "/remote/").map({ String(cwd[..<$0.lowerBound]) }) else { return nil }
        let remotes = Remotes(home: URL(fileURLWithPath: home))
        if remotes.of(cwd) != nil { return (cwd, remotes) }
        return remotes.containing(cwd).map { ($0.folder, remotes) }
    }

    /// Returns "owner/repo" (or "host/owner/repo" off github.com) for gh's GH_REPO. Returns nil for a project on this
    /// Mac, or for one whose origin isn't on a GitHub.
    static func github(_ cwd: String) -> String? {
        guard let (folder, remotes) = project(cwd) else { return nil }
        let fresh = { known.withLock { $0[folder] }.flatMap { Date().timeIntervalSince($0.at) < 600 ? $0 : nil } }
        if let hit = fresh() { return hit.repo }
        // A folder's origin is read by one request at a time. Requests that come meanwhile (the sidebar's, for every
        // folder at once) wait for that answer instead of each dialing the host.
        let turn = reading.withLock { turns -> NSLock in
            if let turn = turns[folder] { return turn }
            let turn = NSLock()
            turns[folder] = turn
            return turn
        }
        turn.lock()
        defer { turn.unlock() }
        if let hit = fresh() { return hit.repo }
        let origin = Logger.kelp("integrations").attempt("reading \(folder)'s origin") {
            try Git.origin(folder, remotes: remotes)
        }
        let repo = origin.flatMap { origin -> String? in
            guard Forge.of(remote: origin) == .github, let (host, path) = Git.webRepo(origin) else { return nil }
            return host == "github.com" ? path : host + "/" + path
        }
        known.withLock { $0[folder] = (repo, Date()) }
        return repo
    }
}
