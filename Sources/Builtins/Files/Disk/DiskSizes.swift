import Core
import DesignKit
import Foundation
import KelpKit
import Observation

/// How much disk each project takes, on this Mac or on a remote project's host, as last measured (`repo.diskUsage`).
/// The Files footer and the Disk Usage tab read it, and measure again when the number is missing or old, so measuring
/// happens only while one of them is on screen. The app has one of these, made with the Files built-in's contributions
/// and handed to both.
@MainActor @Observable
final class DiskSizes {
    struct Measured {
        var items: [RepoDiskUsage.Item]
        var at: Date
    }
    private(set) var byRepo: [String: Measured] = [:]
    private(set) var measuring: Set<String> = []
    /// Why the last measure failed, such as a host out of reach. The tab shows the reason, and the footer shows
    /// nothing.
    private(set) var failed: [String: String] = [:]
    /// A measure this recent is shown as it is, without measuring again.
    static let fresh: TimeInterval = 600

    func measure(_ repoId: String, app: AppModel, again: Bool = false) {
        let old = byRepo[repoId].map { -$0.at.timeIntervalSinceNow > Self.fresh } ?? true
        guard !measuring.contains(repoId), again || old else { return }
        measuring.insert(repoId)
        Task {
            let (items, error) = await app.tryCall(RepoDiskUsage(id: repoId))
            if let items { byRepo[repoId] = Measured(items: items, at: Date()) }
            failed[repoId] = error
            measuring.remove(repoId)
        }
    }
}

/// The three kinds of space a project's parts are sorted into.
enum DiskGroup: CaseIterable {
    /// The next build makes it again.
    case rebuilds
    /// Only the user knows whether it can go, as with other files git ignores, or another worktree.
    case check
    /// Kelp doesn't offer to remove it, as with Claude Code's chats or what git tracks.
    case leftAlone

    init(_ item: RepoDiskUsage.Item) {
        self = item.what.leftAlone ? .leftAlone : item.what.rebuilds && item.removable ? .rebuilds : .check
    }

    var title: String {
        switch self {
        case .rebuilds: String(localized: "Safe to remove")
        case .check: String(localized: "Check first")
        case .leftAlone: String(localized: "Left alone")
        }
    }
}

extension [RepoDiskUsage.Item] {
    var bytes: Int { reduce(0) { $0 + $1.bytes } }
    func of(_ group: DiskGroup) -> [RepoDiskUsage.Item] { filter { DiskGroup($0) == group } }
}

/// How a part is named and described: by its path in the project, else by what it is.
enum DiskNames {
    static func name(_ item: RepoDiskUsage.Item, root: String) -> String {
        switch item.what {
        case .chats: return String(localized: "Claude Code chats")
        case .files: return String(localized: "Project files")
        default:
            // A build in another worktree is named with that worktree's name, as in `black-theme/.build`.
            let base = item.worktree.map { ($0 as NSString).deletingLastPathComponent } ?? root
            return Paths.relative(item.path, to: base) ?? (item.path as NSString).lastPathComponent
        }
    }

    static func detail(_ item: RepoDiskUsage.Item) -> String {
        let worktree = item.worktree.map { ($0 as NSString).lastPathComponent }
        switch item.what {
        case .build where item.path.contains("/DerivedData/"): return String(localized: "Xcode builds it again")
        case .build:
            return worktree.map { String(localized: "A build in worktree \($0)") }
                ?? String(localized: "The next build makes it again")
        case .ignored:
            return item.removable ? String(localized: "Ignored by git") : String(localized: "A worktree is inside it")
        case .worktree:
            return item.removable
                ? String(localized: "Worktree with nothing uncommitted")
                : String(localized: "Worktree in use or with work")
        case .chats: return String(localized: "Claude Code’s own")
        case .files: return String(localized: "Tracked by git, with .git")
        }
    }

    static func size(_ bytes: Int) -> String { DesignKit.bytes(bytes, file: true) }

    /// Says whose disk the sizes are of: this Mac's, or for a remote project its host's disk (`host`), measured there.
    static func place(host: String?) -> String {
        host.map { String(localized: "on \($0)") } ?? String(localized: "on this Mac")
    }

    /// The footer's words after the size: how much of it the next build makes again, or else whose disk it is on.
    static func foot(_ items: [RepoDiskUsage.Item], host: String?) -> String {
        let rebuilds = items.of(.rebuilds).bytes
        return rebuilds > 0 ? String(localized: "\(size(rebuilds)) rebuilds") : place(host: host)
    }

    /// The title of the button for the chosen parts. A host has no Trash, so there the parts are moved aside instead
    /// (`aside(on:)` says where, and `moved` says that they went).
    static func move(count: Int, host: String?) -> String {
        if host != nil {
            return count == 1 ? String(localized: "Move 1 Item Aside") : String(localized: "Move \(count) Items Aside")
        }
        return count == 1
            ? String(localized: "Move 1 Item to Trash") : String(localized: "Move \(count) Items to Trash")
    }

    /// Says where a host's parts go and for how long, before they go, as the button's help.
    static func aside(on host: String) -> String {
        String(localized: "Into the project’s .git/kelp-trash on \(host), which keeps them a week.")
    }

    /// Says what went, where it went, and that the space isn't freed yet: the Trash holds it until it is emptied, and a
    /// host's .git/kelp-trash (the Files panel's trash there) holds it for a week. `what` is the part's name when only
    /// one went, or nil for several.
    static func moved(_ what: String?, count: Int, size: String, host: String?) -> String {
        if let host {
            guard let what else {
                return String(
                    localized: "Moved \(count) items aside on \(host) (\(size)): .git/kelp-trash keeps them a week.")
            }
            return String(localized: "Moved \(what) aside on \(host) (\(size)): .git/kelp-trash keeps it a week.")
        }
        guard let what else {
            return String(localized: "Moved \(count) items to the Trash (\(size)). Empty the Trash to free them.")
        }
        return String(localized: "Moved \(what) to the Trash (\(size)). Empty the Trash to free it.")
    }
}
