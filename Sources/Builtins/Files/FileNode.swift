import AppKit
import Core
import KelpKit
import Markdown
import Quartz
import WorkbenchKit

final class FileNode: NSObject {
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
        for (p, isIgnored) in paths.lazy.map({ ($0, false) }) + ignored.lazy.map({ ($0, true) }) {
            let parts = p.split(separator: "/").map(String.init), dir = p.hasSuffix("/")
            var parent = root, acc = ""
            for (i, part) in parts.enumerated() {
                acc = acc.isEmpty ? part : acc + "/" + part
                if let d = dirs[acc] {
                    parent = d
                    continue
                }   // an ignored folder with tracked files in it: those show
                let n = FileNode(
                    name: part, path: acc, dir: dir || i < parts.count - 1, ignored: isIgnored && i == parts.count - 1)
                parent.children?.append(n)
                if n.children != nil {
                    dirs[acc] = n
                    parent = n
                }
            }
        }
        sort(root)
        return root.children ?? []
    }

    /// An ignored folder's files as `files.ignored` lists them (each path from the root).
    func read(_ entries: [String]) {
        unread = false
        children = entries.map { e in
            FileNode(
                name: (e as NSString).lastPathComponent, path: String(e.dropLast(e.hasSuffix("/") ? 1 : 0)),
                dir: e.hasSuffix("/"), ignored: true)
        }
        Self.sort(self)
    }

    /// The node at `rel` under `nodes`.
    static func find(_ rel: String, in nodes: [FileNode]) -> FileNode? {
        var list = nodes, found: FileNode?
        for part in rel.split(separator: "/") {
            guard let f = list.first(where: { $0.name == part }) else { return nil }
            found = f
            list = f.children ?? []
        }
        return found
    }

    // Keys made once per node: lowercasing inside the comparator did it n log n times (100k files in a big repo).
    private static func sort(_ n: FileNode) {
        n.children = n.children?.map { ($0.children != nil ? 0 : 1, $0.name.lowercased(), $0) }.sorted {
            ($0.0, $0.1) < ($1.0, $1.1)
        }.map(\.2)
        n.children?.forEach(sort)
    }
}
