import AppKit
import Core
import Quartz

/// A file or folder in the Files tree. The tree is built off the main actor (`update`), then read and changed only on
/// the main actor.
final class FileNode: NSObject, @unchecked Sendable {
    let name: String, path: String   // path relative to worktree root
    var children: [FileNode]?   // nil = file
    /// `ignored`: git ignores this node, so it's drawn dimmed, as VS Code does. `unread`: an ignored folder whose files
    /// aren't read until it opens.
    let ignored: Bool
    var unread: Bool
    init(name: String, path: String, dir: Bool, ignored: Bool = false) {
        self.name = name
        self.path = path
        children = dir ? [] : nil
        self.ignored = ignored
        unread = ignored && dir
    }

    /// Builds a sorted tree, folders first, from relative paths and the paths git ignores. In `ignored`, as
    /// `files.ignored` lists it, a folder ends with "/".
    static func tree(_ paths: [String], ignored: [String] = []) -> [FileNode] {
        let root = FileNode(name: "", path: "", dir: true)
        var dirs: [String: FileNode] = ["": root]
        for (path, isIgnored) in paths.lazy.map({ ($0, false) }) + ignored.lazy.map({ ($0, true) }) {
            let parts = path.split(separator: "/").map(String.init), dir = path.hasSuffix("/")
            var parent = root, acc = ""
            for (index, part) in parts.enumerated() {
                acc = acc.isEmpty ? part : acc + "/" + part
                if let folder = dirs[acc] {
                    parent = folder
                    continue
                }   // tracked files inside an ignored folder still show
                let node = FileNode(
                    name: part, path: acc, dir: dir || index < parts.count - 1,
                    ignored: isIgnored && index == parts.count - 1)
                parent.children?.append(node)
                if node.children != nil {
                    dirs[acc] = node
                    parent = node
                }
            }
        }
        sort(root)
        return root.children ?? []
    }

    /// Fills this ignored folder with its files, as `files.ignored` lists them (each path from the root).
    func read(_ entries: [String]) {
        unread = false
        children = entries.map { entry in
            FileNode(
                name: (entry as NSString).lastPathComponent, path: String(entry.dropLast(entry.hasSuffix("/") ? 1 : 0)),
                dir: entry.hasSuffix("/"), ignored: true)
        }
        Self.sort(self)
    }

    /// The node at `rel` under `nodes`.
    static func find(_ rel: String, in nodes: [FileNode]) -> FileNode? {
        var list = nodes, found: FileNode?
        for part in rel.split(separator: "/") {
            guard let child = list.first(where: { $0.name == part }) else { return nil }
            found = child
            list = child.children ?? []
        }
        return found
    }

    /// Where the node sorts among its folder's nodes: folders first, then by name, ignoring case.
    private var order: (Int, String) { (children != nil ? 0 : 1, name.lowercased()) }

    // Each node's sort key is made once, because lowercasing inside the comparator ran n log n times (100k files in a
    // big repo).
    private static func sort(_ node: FileNode) {
        node.children = node.children?.map { ($0.order, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        node.children?.forEach(sort)
    }

    /// Gives the ignored folders that were opened and read (`opened`) their files again in a newly built tree, outer
    /// folders first.
    static func open(_ opened: [String: [String]], in nodes: [FileNode]) {
        for folder in opened.keys.sorted(by: { $0.count < $1.count }) {
            find(folder, in: nodes).map { if $0.ignored { $0.read(opened[folder] ?? []) } }
        }
    }
}

/// How a new listing changes the tree: not at all, by a few files added or removed, or with a whole new tree.
enum TreeUpdate: Sendable {
    case same, patch(added: [String], removed: [String]), tree([FileNode])
}

/// One row inserted into or removed from the tree. Edits come in the order they happened, and a nil `parent` is the
/// top level.
struct TreeEdit {
    let parent: FileNode?, index: Int, inserted: Bool
}

extension FileNode {
    /// More changed paths than this mean the listing changed as a whole (a checkout, a pull), so the tree is built
    /// again.
    static let mostPatched = 64

    /// Works out how the tree changes from the listing it was built from (`was`, nil when there was none) to the new
    /// one. It runs off the main actor, because comparing and building 100k paths there held up the window. The tree is
    /// built again when what's ignored changed, or when a changed path lies in an opened ignored folder (`opened`),
    /// whose files the listing doesn't name.
    static func update(
        was: (paths: [String], ignored: [String])?, paths: [String], ignored: [String], opened: [String: [String]]
    ) -> TreeUpdate {
        if let was, was.ignored == ignored {
            if was.paths == paths { return .same }
            let old = Set(was.paths), new = Set(paths)
            let added = paths.filter { !old.contains($0) }, removed = was.paths.filter { !new.contains($0) }
            let inOpened = (added + removed).contains { path in opened.keys.contains { path.hasPrefix($0 + "/") } }
            if added.count + removed.count <= mostPatched, !inOpened { return .patch(added: added, removed: removed) }
        }
        let nodes = tree(paths, ignored: ignored)
        open(opened, in: nodes)
        return .tree(nodes)
    }

    /// Takes the `removed` files out of the tree, with any folders they leave empty, and puts the `added` files in,
    /// each at its sorted place in its folder. Returns the edits in the order they were made. Returns nil and leaves
    /// the tree as it was when a path changed between file and folder, because the tree is built again then.
    static func patch(_ nodes: inout [FileNode], added: [String], removed: [String]) -> [TreeEdit]? {
        let root = FileNode(name: "", path: "", dir: true)
        root.children = nodes
        guard removed.allSatisfy({ root.chain(to: $0)?.last?.children == nil }),
            added.allSatisfy({ root.fits($0) })
        else { return nil }
        var edits: [TreeEdit] = []
        func edit(_ parent: FileNode, _ index: Int, _ inserted: Bool) {
            edits.append(TreeEdit(parent: parent === root ? nil : parent, index: index, inserted: inserted))
        }
        for path in removed { root.remove(path, edit) }
        var fresh = Set<ObjectIdentifier>()   // the folders just added, whose contents the outline asks for itself
        for path in added { root.add(path, fresh: &fresh, edit) }
        nodes = root.children ?? []
        return edits
    }

    /// The nodes from this one down to `path`, with the node at `path` last, or nil if `path` isn't in the tree.
    private func chain(to path: String) -> [FileNode]? {
        var out = [self]
        for part in path.split(separator: "/") {
            guard let child = out.last?.children?.first(where: { $0.name == part }) else { return nil }
            out.append(child)
        }
        return out
    }

    /// Whether `path` can go in as a file: no file stands on its way, and no folder stands in its place.
    private func fits(_ path: String) -> Bool {
        guard !path.hasSuffix("/") else { return false }   // the path names a folder
        var node: FileNode? = self
        for part in path.split(separator: "/") {
            guard let next = node?.children?.first(where: { $0.name == part }) else { return true }
            guard next.children != nil else { return next.path == path }   // already there as a file
            node = next
        }
        return false
    }

    private func remove(_ path: String, _ edit: (FileNode, Int, Bool) -> Void) {
        guard var chain = chain(to: path) else { return }
        // Removes the file, then each folder it leaves empty. An empty ignored folder stays, as a newly built tree
        // would keep it.
        while chain.count > 1, let gone = chain.popLast(), let parent = chain.last,
            let index = parent.children?.firstIndex(of: gone)
        {
            parent.children?.remove(at: index)
            edit(parent, index, false)
            guard parent.children?.isEmpty == true, !parent.ignored else { return }
        }
    }

    private func add(_ path: String, fresh: inout Set<ObjectIdentifier>, _ edit: (FileNode, Int, Bool) -> Void) {
        let parts = path.split(separator: "/").map(String.init)
        var parent = self, acc = ""
        for (index, part) in parts.enumerated() {
            acc = acc.isEmpty ? part : acc + "/" + part
            if let next = parent.children?.first(where: { $0.name == part }) {
                parent = next
                continue
            }
            let node = FileNode(name: part, path: acc, dir: index < parts.count - 1)
            let at = parent.children?.firstIndex { $0.order > node.order } ?? parent.children?.count ?? 0
            parent.children?.insert(node, at: at)
            if !fresh.contains(ObjectIdentifier(parent)) { edit(parent, at, true) }
            if node.children != nil { fresh.insert(ObjectIdentifier(node)) }
            parent = node
        }
    }
}
