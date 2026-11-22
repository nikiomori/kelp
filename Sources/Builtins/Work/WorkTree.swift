import Core
import Foundation

/// A project's places as a tree, for the Work panel's layers and the Map tab: folders, then files, by name, as Finder
/// sorts them, so a live map doesn't reorder itself as the agent works. A folder with one folder in it shows as one
/// (`Daemon/Sessions`), as the measured trees run 3 to 7 levels deep that way.
struct WorkNode: Equatable, Sendable {
    /// The path from the project's root ("" for the root).
    var path: String
    /// What the node shows: a name, or a merged chain of folders ("Daemon/Sessions").
    var name: String
    /// The file this node is, or nil for a folder.
    var place: AgentWork.Place?
    /// Whether the folder was searched (Grep, Glob, `rg`) as well as, or instead of, opened.
    var searched = false
    var children: [WorkNode] = []

    var isFile: Bool { place != nil }
    /// The files under it, itself for a file. A searched folder with none counts one, so it still shows.
    var weight: Int { isFile ? 1 : max(children.reduce(0) { $0 + $1.weight }, searched ? 1 : 0) }
    var edited: Bool { (place.map { $0.edits > 0 || $0.byCommand } ?? false) || children.contains(where: \.edited) }
    var files: [WorkNode] { isFile ? [self] : children.flatMap(\.files) }
    var agents: Set<Int> { Set(place?.agents ?? []).union(children.flatMap(\.agents)) }

    /// The node at `path`, itself included.
    func node(at path: String) -> WorkNode? {
        if self.path == path { return self }
        return children.lazy.compactMap { $0.node(at: path) }.first
    }
}

enum WorkTree {
    /// The project's files and searched folders as a tree named `rootName`. With `agents`, only what they touched.
    static func project(_ work: AgentWork, rootName: String, agents: Set<Int>? = nil) -> WorkNode {
        var root = WorkNode(path: "", name: rootName)
        for place in work.places where place.kind == .file || place.kind == .folder {
            guard agents.map({ !$0.isDisjoint(with: place.agents) }) ?? true else { continue }
            let parts = place.name == "." ? [] : place.name.split(separator: "/").map(String.init)
            insert(place, parts: parts[...], into: &root, prefix: "")
        }
        sort(&root)
        merge(&root, isRoot: true)
        return root
    }

    /// The places outside the project, in the order the panel lists them: sites, machines, tools, packages, other
    /// folders, then the agent's own folders.
    static func outside(_ work: AgentWork, agents: Set<Int>? = nil) -> [AgentWork.Place] {
        let order: [AgentWork.Kind] = [.web, .machine, .tool, .packages, .outside, .own]
        return work.places.filter { place in
            order.contains(place.kind) && (agents.map { !$0.isDisjoint(with: place.agents) } ?? true)
        }
        .sorted {
            let (a, b) = (order.firstIndex(of: $0.kind) ?? 0, order.firstIndex(of: $1.kind) ?? 0)
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func insert(
        _ place: AgentWork.Place, parts: ArraySlice<String>, into node: inout WorkNode, prefix: String
    ) {
        guard let first = parts.first else {
            // A folder that was searched, or the project's root touched as a whole (a worktree's own folder).
            if place.kind == .folder || node.path.isEmpty { node.searched = true } else { node.place = place }
            return
        }
        let path = prefix.isEmpty ? first : prefix + "/" + first
        let index =
            node.children.firstIndex { $0.path == path }
            ?? {
                node.children.append(WorkNode(path: path, name: first))
                return node.children.count - 1
            }()
        insert(place, parts: parts.dropFirst(), into: &node.children[index], prefix: path)
    }

    private static func sort(_ node: inout WorkNode) {
        for index in node.children.indices { sort(&node.children[index]) }
        node.children.sort { a, b in
            a.isFile != b.isFile ? !a.isFile : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// A folder whose only child is a folder takes it in: "Daemon" + "Sessions" shows as "Daemon/Sessions".
    private static func merge(_ node: inout WorkNode, isRoot: Bool) {
        for index in node.children.indices { merge(&node.children[index], isRoot: false) }
        if !isRoot, !node.isFile, !node.searched, node.children.count == 1, let only = node.children.first, !only.isFile
        {
            node = WorkNode(
                path: only.path, name: node.name + "/" + only.name, place: nil, searched: only.searched,
                children: only.children)
        }
    }
}
