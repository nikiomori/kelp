import AppKit
import Core
import Quartz

/// Built off the main actor (`update`), then read and changed only on it.
final class FileNode: NSObject, @unchecked Sendable {
    let name: String, path: String   // path relative to worktree root
    var children: [FileNode]?   // nil = file
    /// Git ignores it (drawn dimmed, like VS Code's). `unread`: an ignored folder whose files are read when it opens.
    let ignored: Bool
    var unread: Bool
    init(name: String, path: String, dir: Bool, ignored: Bool = false) {
        self.name = name
        self.path = path
        children = dir ? [] : nil
        self.ignored = ignored
        unread = ignored && dir
    }

    /// Build a sorted tree (folders first) from relative paths, and what git ignores (`files.ignored`: a folder ends with "/").
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
                }   // an ignored folder with tracked files in it: those show
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

    /// An ignored folder's files as `files.ignored` lists them (each path from the root).
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

    // Keys made once per node: lowercasing inside the comparator did it n log n times (100k files in a big repo).
    private static func sort(_ node: FileNode) {
        node.children = node.children?.map { ($0.order, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        node.children?.forEach(sort)
    }

    /// The ignored folders read open (`opened`, outer first) take their files again in a tree just built.
    static func open(_ opened: [String: [String]], in nodes: [FileNode]) {
        for folder in opened.keys.sorted(by: { $0.count < $1.count }) {
            find(folder, in: nodes).map { if $0.ignored { $0.read(opened[folder] ?? []) } }
        }
    }
}

/// What a new listing does to the tree: nothing, a few files in or out, or a new tree.
enum TreeUpdate: Sendable {
    case same, patch(added: [String], removed: [String]), tree([FileNode])
}

/// A row in or out of the tree, in the order they happened: `parent` nil is the top level.
struct TreeEdit {
    let parent: FileNode?, index: Int, inserted: Bool
}

extension FileNode {
    /// More than this is the listing changing as a whole (a checkout, a pull): the tree is built again.
    static let mostPatched = 64

    /// From the listing the tree was built from (`was`; nil, none) to the new one, off the main actor: comparing and
    /// building 100k paths there held up the window. A path in an ignored folder read open (`opened`), whose files the
    /// listing doesn't name, or a change in what's ignored builds it again.
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

    /// Takes the `removed` files out of the tree (and their folders left empty) and puts the `added` ones in, each where
    /// its folder sorts it; the edits say where, one after another. Nil, and the tree as it was, when a path changed
    /// between file and folder: it's built again then.
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
        var fresh = Set<ObjectIdentifier>()   // folders made here: the outline asks for what's in them
        for path in added { root.add(path, fresh: &fresh, edit) }
        nodes = root.children ?? []
        return edits
    }

    /// The nodes from here down to `path`, it last; nil if it isn't in the tree.
    private func chain(to path: String) -> [FileNode]? {
        var out = [self]
        for part in path.split(separator: "/") {
            guard let child = out.last?.children?.first(where: { $0.name == part }) else { return nil }
            out.append(child)
        }
        return out
    }

    /// `path` can go in as a file: no file on its way, no folder in its place.
    private func fits(_ path: String) -> Bool {
        guard !path.hasSuffix("/") else { return false }   // a folder listed as one
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
        // The file, then each folder it leaves empty (an ignored one stays, as a new tree keeps it).
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
